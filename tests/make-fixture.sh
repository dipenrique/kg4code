#!/bin/sh
# Builds a throwaway multi-root fixture for kg-setup tests. Usage: sh make-fixture.sh <dir>
set -e
D=$1
rm -rf "$D"; mkdir -p "$D/ws/repo-a/src" "$D/repo-b/lib"
G="git -c user.email=t@t -c user.name=t"

# repo-a: fresh JS repo with pre-existing hooks and agent config
cd "$D/ws/repo-a"
git init -q
printf 'export function add (a, b) { return a + b }\nexport function twice (x) { return add(x, x) }\n' > src/math.js
printf 'import { twice } from "./math.js"\nconsole.log(twice(2))\n' > src/main.js
printf 'node_modules/\n' > .gitignore
mkdir -p .claude .vscode .github/hooks
cat > .claude/settings.json << 'EOF'
{
  "permissions": { "allow": ["Bash(npm test)"] },
  "hooks": {
    "SessionStart": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "node agentmemory/session-start.mjs" },
        { "type": "command", "command": "code-review-graph status" }
      ] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write", "hooks": [ { "type": "command", "command": "code-review-graph update --skip-flows", "timeout": 30 } ] }
    ]
  }
}
EOF
cat > .vscode/settings.json << 'EOF'
{
  // editor prefs
  "editor.tabSize": 2,
}
EOF
printf '{ "hooks": { "Stop": [ { "type": "command", "command": "code-review-graph update && code-review-graph embed" } ] } }\n' > .github/hooks/code-review-graph.json
printf '{ "hooks": { "Stop": [ { "type": "command", "command": "node agentmemory/stop.mjs" } ] } }\n' > .github/hooks/agentmemory.json
$G add . && $G commit -qm init
printf '#!/bin/sh\necho "existing pre-commit ran" >&2\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

# repo-b: python repo, sibling folder, no agent config at all
cd "$D/repo-b"
git init -q
printf 'def area(r):\n    return 3.14 * r * r\n\n\ndef ring(a, b):\n    return area(a) - area(b)\n' > lib/geo.py
$G add . && $G commit -qm init

# multi-root workspace file (JSONC with comments) inside repo-a's parent
cat > "$D/ws/fixture.code-workspace" << 'EOF'
{
	// fixture workspace
	"folders": [
		{ "path": "repo-a" },
		{ "path": "../repo-b" }
	],
	"settings": {
		"files.trimTrailingWhitespace": true
	}
}
EOF
echo "fixture ready: $D"
