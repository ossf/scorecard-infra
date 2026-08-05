/*
Copyright 2026 The uwu-tools Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package store

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/uwu-tools/scorecard-api/internal/model"
)

const testCommit = "2418d6d95e928102e1f3f8d6e7b92f4f3c78631f"

func testRef(t *testing.T) model.RepoRef {
	t.Helper()
	ref, err := model.ParseRepoRef("github.com", "ossf", "scorecard")
	if err != nil {
		t.Fatalf("ParseRepoRef: %v", err)
	}
	return ref
}

// openStore opens a store at bucketURL and closes it at test end.
func openStore(t *testing.T, bucketURL string) *Store {
	t.Helper()
	s, err := Open(context.Background(), bucketURL)
	if err != nil {
		t.Fatalf("Open(%q): %v", bucketURL, err)
	}
	t.Cleanup(func() {
		if err := s.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return s
}

func TestKey(t *testing.T) {
	t.Parallel()

	ref := testRef(t)
	if got, want := Key(ref, ""), "github.com/ossf/scorecard/results.json"; got != want {
		t.Errorf("Key(latest) = %q, want %q", got, want)
	}
	if got, want := Key(ref, testCommit), "github.com/ossf/scorecard/"+testCommit+"/results.json"; got != want {
		t.Errorf("Key(commit) = %q, want %q", got, want)
	}
}

func TestOpenEmptyURL(t *testing.T) {
	t.Parallel()

	if _, err := Open(context.Background(), ""); !errors.Is(err, errEmptyBucketURL) {
		t.Fatalf("Open(\"\") error = %v, want errEmptyBucketURL", err)
	}
}

func TestGetNotFound(t *testing.T) {
	t.Parallel()

	s := openStore(t, "mem://")
	if _, err := s.Get(context.Background(), testRef(t), ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get(miss) error = %v, want ErrNotFound", err)
	}
}

func TestRoundTrip(t *testing.T) {
	t.Parallel()

	runRoundTrip(t, "mem://")
}

// runRoundTrip exercises the full Put/Get contract against a bucket URL. It is
// shared by the in-memory, fileblob, and S3-compatible backend tests.
func runRoundTrip(t *testing.T, bucketURL string) {
	t.Helper()

	ctx := context.Background()
	s := openStore(t, bucketURL)
	ref := testRef(t)
	latest := []byte(`{"score":8.9,"latest":true}`)
	pinned := []byte(`{"score":7.0,"commit":true}`)

	if err := s.Put(ctx, ref, "", latest); err != nil {
		t.Fatalf("Put(latest): %v", err)
	}
	if got, err := s.Get(ctx, ref, ""); err != nil || !bytes.Equal(got, latest) {
		t.Fatalf("Get(latest) = %q, %v; want %q", got, err, latest)
	}

	if err := s.Put(ctx, ref, testCommit, pinned); err != nil {
		t.Fatalf("Put(commit): %v", err)
	}
	if got, err := s.Get(ctx, ref, testCommit); err != nil || !bytes.Equal(got, pinned) {
		t.Fatalf("Get(commit) = %q, %v; want %q", got, err, pinned)
	}

	// The commit write must not have clobbered the independent latest pointer.
	if got, err := s.Get(ctx, ref, ""); err != nil || !bytes.Equal(got, latest) {
		t.Fatalf("Get(latest) after commit write = %q, %v; want %q", got, err, latest)
	}
}

func TestPutLatestAndCommit(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	s := openStore(t, "mem://")
	ref := testRef(t)
	body := []byte(`{"score":9.1}`)

	if err := s.PutLatestAndCommit(ctx, ref, testCommit, body); err != nil {
		t.Fatalf("PutLatestAndCommit: %v", err)
	}
	for _, commit := range []string{"", testCommit} {
		got, err := s.Get(ctx, ref, commit)
		if err != nil || !bytes.Equal(got, body) {
			t.Errorf("Get(%q) = %q, %v; want %q", commit, got, err, body)
		}
	}

	if err := s.PutLatestAndCommit(ctx, ref, "", body); !errors.Is(err, errEmptyCommit) {
		t.Errorf("PutLatestAndCommit(empty commit) error = %v, want errEmptyCommit", err)
	}
}

// TestRoundTripFileblob runs the contract against a local-filesystem bucket.
func TestRoundTripFileblob(t *testing.T) {
	t.Parallel()

	runRoundTrip(t, "file://"+t.TempDir())
}

func TestDefaultFileNoTempDir(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		in   string
		want string
	}{
		{"file url gets the default", "file:///data", "file:///data?no_tmp_dir=true"},
		{"existing params are preserved", "file:///data?create_dir=true", "file:///data?create_dir=true&no_tmp_dir=true"},
		{"explicit value is not overridden", "file:///data?no_tmp_dir=false", "file:///data?no_tmp_dir=false"},
		{"non-file scheme is untouched", "mem://", "mem://"},
		{"s3 scheme is untouched", "s3://bucket?region=us-east-1", "s3://bucket?region=us-east-1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got, err := defaultFileNoTempDir(tc.in)
			if err != nil {
				t.Fatalf("defaultFileNoTempDir(%q): %v", tc.in, err)
			}
			if got != tc.want {
				t.Errorf("defaultFileNoTempDir(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// TestFileblobSurvivesUnwritableTempDir guards the cross-device-rename footgun
// this fix closes: fileblob's default behavior writes its temp file in
// os.TempDir() before renaming it into place, which fails with "invalid
// cross-device link" whenever the bucket directory is a separate mount from
// os.TempDir (true for any container volume, bind mount, or Kubernetes PVC).
// Pointing TMPDIR at a nonexistent path simulates that: with no_tmp_dir
// defaulted on, the temp file is created next to the destination instead, so
// TMPDIR is never touched and the round trip still succeeds.
func TestFileblobSurvivesUnwritableTempDir(t *testing.T) {
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "does-not-exist"))

	runRoundTrip(t, "file://"+t.TempDir())
}

// TestRoundTripS3 runs the contract against an S3-compatible bucket (e.g. a
// self-hosted S3-compatible store).
// It is skipped unless SCORECARD_TEST_S3_URL is set to a gocloud.dev/blob s3://
// URL; credentials resolve via the AWS default chain.
func TestRoundTripS3(t *testing.T) {
	t.Parallel()

	bucketURL := os.Getenv("SCORECARD_TEST_S3_URL")
	if bucketURL == "" {
		t.Skip("set SCORECARD_TEST_S3_URL (e.g. a local S3-compatible s3:// URL) to run the S3 integration test")
	}
	runRoundTrip(t, bucketURL)
}
