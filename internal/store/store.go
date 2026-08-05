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

// Package store persists Scorecard results in a cloud-agnostic object store via
// gocloud.dev/blob. The backend (S3-compatible, Azure Blob, GCS,
// local file, or in-memory) is selected entirely by the bucket URL, so nothing
// cloud-specific is compiled in (design D3).
//
// Object keys match ossf/scorecard-webapp exactly (design D4, confirmed in
// task 0.3):
//
//	{host}/{org}/{repo}/results.json            latest (mutable)
//	{host}/{org}/{repo}/{commit}/results.json   pinned (immutable)
//
// Bodies are canonical Scorecard JSON2.
package store

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"path"

	"gocloud.dev/blob"
	// Blank-import every backend driver so a bucket URL alone selects the
	// backend at runtime. Credentials resolve via each backend's default chain.
	_ "gocloud.dev/blob/azureblob"
	_ "gocloud.dev/blob/fileblob"
	_ "gocloud.dev/blob/gcsblob"
	_ "gocloud.dev/blob/memblob"
	_ "gocloud.dev/blob/s3blob"
	"gocloud.dev/gcerrors"

	"github.com/uwu-tools/scorecard-api/internal/model"
)

// resultsObject is the fixed object filename for a stored result, matching the
// scorecard-webapp key contract.
const resultsObject = "results.json"

// contentTypeJSON is set on every stored object so backends and CDNs serve the
// canonical JSON2 body with the correct media type.
const contentTypeJSON = "application/json"

// ErrNotFound is returned when no stored result exists for the requested key.
// The orchestrator treats it as a cache miss (design D2), not a fatal error.
var ErrNotFound = errors.New("store: result not found")

// errEmptyBucketURL is returned by Open when no bucket URL is configured.
var errEmptyBucketURL = errors.New("store: bucket URL is empty")

// Store is a cloud-agnostic Scorecard result store backed by gocloud.dev/blob.
type Store struct {
	bucket *blob.Bucket
}

// Open opens the bucket addressed by a gocloud.dev/blob URL, e.g.
// "file:///var/scorecard", "s3://my-bucket?region=us-east-1", or "mem://".
// It fails fast when the URL is empty or the backend cannot be opened.
func Open(ctx context.Context, bucketURL string) (*Store, error) {
	if bucketURL == "" {
		return nil, errEmptyBucketURL
	}
	bucketURL, err := defaultFileNoTempDir(bucketURL)
	if err != nil {
		return nil, err
	}
	bucket, err := blob.OpenBucket(ctx, bucketURL)
	if err != nil {
		return nil, fmt.Errorf("store: opening bucket: %w", err)
	}
	return &Store{bucket: bucket}, nil
}

// defaultFileNoTempDir defaults fileblob's "no_tmp_dir" query parameter to
// true for file:// URLs that don't already set it. Without it, fileblob
// writes a temp file in os.TempDir() and renames it into place; if the bucket
// directory is a separate mount from os.TempDir — true for a container's
// named volume, bind mount, or a Kubernetes PVC, i.e. true for essentially
// any real deployment — that rename fails with "invalid cross-device link".
// Placing the temp file next to the final path instead avoids the whole
// class of failure. Non-file schemes are returned unchanged.
func defaultFileNoTempDir(bucketURL string) (string, error) {
	u, err := url.Parse(bucketURL)
	if err != nil {
		return "", fmt.Errorf("store: parsing bucket URL: %w", err)
	}
	if u.Scheme != "file" {
		return bucketURL, nil
	}
	q := u.Query()
	if q.Get("no_tmp_dir") == "" {
		q.Set("no_tmp_dir", "true")
		u.RawQuery = q.Encode()
	}
	return u.String(), nil
}

// Close releases the underlying bucket.
func (s *Store) Close() error {
	if err := s.bucket.Close(); err != nil {
		return fmt.Errorf("store: closing bucket: %w", err)
	}
	return nil
}

// Key returns the object key for a repository reference and optional commit.
// An empty commit yields the mutable "latest" key; a non-empty commit yields the
// immutable commit-pinned key. Segments are joined with "/" regardless of OS.
func Key(ref model.RepoRef, commit string) string {
	if commit == "" {
		return path.Join(ref.Host, ref.Org, ref.Repo, resultsObject)
	}
	return path.Join(ref.Host, ref.Org, ref.Repo, commit, resultsObject)
}

// Get returns the stored JSON2 body for ref at commit (empty commit = latest).
// It returns ErrNotFound when no object exists at the key, distinct from an I/O
// error.
func (s *Store) Get(ctx context.Context, ref model.RepoRef, commit string) ([]byte, error) {
	key := Key(ref, commit)
	body, err := s.bucket.ReadAll(ctx, key)
	if err != nil {
		if gcerrors.Code(err) == gcerrors.NotFound {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("store: reading %q: %w", key, err)
	}
	return body, nil
}

// Put writes body to the key for ref at commit (empty commit = latest). This
// writes exactly one object; use PutLatestAndCommit to populate both the latest
// pointer and the commit-pinned object from one scan.
func (s *Store) Put(ctx context.Context, ref model.RepoRef, commit string, body []byte) error {
	return s.write(ctx, Key(ref, commit), body)
}

// PutLatestAndCommit writes body to both the commit-pinned key and the latest
// pointer. The orchestrator uses this on a default-branch (latest) scan, where
// the resolved commit is also HEAD, so both keys should reflect it. commit must
// be non-empty.
func (s *Store) PutLatestAndCommit(ctx context.Context, ref model.RepoRef, commit string, body []byte) error {
	if commit == "" {
		return fmt.Errorf("%w: commit is empty", errEmptyCommit)
	}
	if err := s.write(ctx, Key(ref, commit), body); err != nil {
		return err
	}
	return s.write(ctx, Key(ref, ""), body)
}

// errEmptyCommit is returned when a commit-pinned write is requested without a
// commit.
var errEmptyCommit = errors.New("store: commit required")

// write stores body at key with the JSON content type.
func (s *Store) write(ctx context.Context, key string, body []byte) error {
	opts := &blob.WriterOptions{ContentType: contentTypeJSON}
	if err := s.bucket.WriteAll(ctx, key, body, opts); err != nil {
		return fmt.Errorf("store: writing %q: %w", key, err)
	}
	return nil
}
