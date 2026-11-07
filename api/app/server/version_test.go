// Copyright 2026 OpenSSF Scorecard Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"runtime/debug"
	"testing"

	"github.com/go-openapi/runtime"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/ossf/scorecard-infra/api/app/generated/models"
	"github.com/ossf/scorecard-infra/api/app/generated/restapi/operations/version"
)

func TestNewVersionInfo(t *testing.T) {
	t.Parallel()
	deps := []*debug.Module{
		{Path: "golang.org/x/mod", Version: "v0.41.0"},
		{Path: "actionlint.kjanat.dev", Version: "v1.17.0"},
	}
	tests := []struct {
		name   string
		ver    string
		commit string
		info   *debug.BuildInfo
		want   models.VersionInfo
	}{
		{
			name:   "release build",
			ver:    "v0.3.0",
			commit: "090dc48ecf5a701e09173c3ce85e85324472c723",
			info:   &debug.BuildInfo{Deps: deps},
			want: models.VersionInfo{
				Version: "v0.3.0",
				Commit:  "090dc48ecf5a701e09173c3ce85e85324472c723",
				Parser:  "actionlint.kjanat.dev v1.17.0",
			},
		},
		{
			// A local `go build` sets neither link-time value.
			name: "nothing injected",
			info: &debug.BuildInfo{Deps: deps},
			want: models.VersionInfo{
				Version: "unknown",
				Commit:  "unknown",
				Parser:  "actionlint.kjanat.dev v1.17.0",
			},
		},
		{
			name: "replaced parser reports the replacement",
			ver:  "v0.3.0", commit: "abc",
			info: &debug.BuildInfo{Deps: []*debug.Module{{
				Path:    "actionlint.kjanat.dev",
				Version: "v1.17.0",
				Replace: &debug.Module{Path: "example.com/actionlint", Version: "v1.17.1"},
			}}},
			want: models.VersionInfo{
				Version: "v0.3.0",
				Commit:  "abc",
				Parser:  "example.com/actionlint v1.17.1",
			},
		},
		{
			name: "parser not linked",
			ver:  "v0.3.0", commit: "abc",
			info: &debug.BuildInfo{Deps: deps[:1]},
			want: models.VersionInfo{Version: "v0.3.0", Commit: "abc", Parser: "unknown"},
		},
		{
			name: "no build info",
			want: models.VersionInfo{Version: "unknown", Commit: "unknown", Parser: "unknown"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			assert.Equal(t, tt.want, *newVersionInfo(tt.ver, tt.commit, tt.info))
		})
	}
}

// The body is checked against buildVersion() rather than a literal parser
// version: under Go 1.26.5 (CI's toolchain), a `go test` binary's build info
// lists no module dependencies, so the parser reads "unknown" here even though
// a real `go build` of the server records it. TestNewVersionInfo covers
// extraction.
func TestGetVersionHandler(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	GetVersionHandler(version.GetVersionParams{}).WriteResponse(rec, runtime.JSONProducer())

	assert.Equal(t, http.StatusOK, rec.Code)
	assert.Equal(t, "max-age=300", rec.Header().Get("Surrogate-Control"))
	assert.Equal(t, "max-age=60", rec.Header().Get("Cache-Control"))
	assert.Equal(t, "scorecard-version", rec.Header().Get("Surrogate-Key"))
	want, err := json.Marshal(buildVersion())
	require.NoError(t, err)
	assert.JSONEq(t, string(want), rec.Body.String())
}
