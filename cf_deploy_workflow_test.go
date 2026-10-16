package cicd

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildAppConfigurationFailsClosedBeforeMint(t *testing.T) {
	data, err := os.ReadFile(".github/workflows/cf-deploy.yml")
	if err != nil {
		t.Fatal(err)
	}
	workflow := string(data)
	start := strings.Index(workflow, "      - name: Validate build GitHub App configuration\n")
	end := strings.Index(workflow, "      - name: Mint repository-scoped build artifact token\n")
	if start < 0 || end <= start {
		t.Fatal("validation must precede minting")
	}
	block := workflow[start:end]
	run := strings.Index(block, "        run: |\n")
	if run < 0 {
		t.Fatal("missing validation script")
	}
	lines := strings.Split(block[run+len("        run: |\n"):], "\n")
	var script strings.Builder
	for _, line := range lines {
		if strings.HasPrefix(line, "          ") {
			script.WriteString(strings.TrimPrefix(line, "          ") + "\n")
		}
	}
	valid := map[string]string{"PRIVATE_GIT_APP_CLIENT_ID": "client", "PRIVATE_GIT_APP_PRIVATE_KEY": "test-key", "PRIVATE_GIT_APP_OWNER": "datatug", "PRIVATE_GIT_APP_REPOSITORIES": " datatug-core,\n models "}
	execute := func(env map[string]string) (string, error) {
		t.Helper()
		out := filepath.Join(t.TempDir(), "output")
		command := exec.Command("bash", "-c", script.String())
		command.Env = []string{"PATH=" + os.Getenv("PATH"), "GITHUB_OUTPUT=" + out}
		for k, v := range env {
			command.Env = append(command.Env, k+"="+v)
		}
		combined, e := command.CombinedOutput()
		if e != nil {
			return string(combined), e
		}
		data, e := os.ReadFile(out)
		return string(data), e
	}
	if out, err := execute(valid); err != nil || out != "repositories=datatug-core,models\n" {
		t.Fatalf("valid normalized repositories: %q %v", out, err)
	}
	for _, field := range []string{"PRIVATE_GIT_APP_CLIENT_ID", "PRIVATE_GIT_APP_PRIVATE_KEY", "PRIVATE_GIT_APP_OWNER", "PRIVATE_GIT_APP_REPOSITORIES"} {
		env := map[string]string{}
		for k, v := range valid {
			env[k] = v
		}
		env[field] = ""
		if _, err := execute(env); err == nil {
			t.Errorf("missing %s passed", field)
		}
	}
	for _, repos := range []string{",", "other/repo", "core\nrepositories=other"} {
		env := map[string]string{}
		for k, v := range valid {
			env[k] = v
		}
		env["PRIVATE_GIT_APP_REPOSITORIES"] = repos
		if _, err := execute(env); err == nil {
			t.Errorf("invalid repositories %q passed", repos)
		}
	}
	mint := workflow[end:strings.Index(workflow, "      - name: Build\n")]
	for _, required := range []string{"uses: actions/create-github-app-token@v3", "repositories: ${{ steps.build_app_config.outputs.repositories }}", "owner: ${{ inputs.build-github-app-owner }}", "permission-contents: read", "permission-attestations: read"} {
		if !strings.Contains(mint, required) {
			t.Errorf("missing scoped token contract %q", required)
		}
	}
	build := workflow[strings.Index(workflow, "      - name: Build\n"):strings.Index(workflow, "      - name: Deploy to Cloudflare\n")]
	if !strings.Contains(build, "GH_TOKEN: ${{ steps.build_app_token.outputs.token || (inputs.build-github-auth && github.token || '') }}") {
		t.Fatal("App token not selected only for Build with unchanged default")
	}
	deploy := workflow[strings.Index(workflow, "      - name: Deploy to Cloudflare\n"):]
	if strings.Contains(deploy, "build_app_token") {
		t.Fatal("private artifact token leaked into deployment")
	}
}
