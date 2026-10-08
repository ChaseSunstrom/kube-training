# Shell helpers for this course: kubectl tab-completion, the `k` alias and a
# few shortcuts. Works in bash (4.1+) and zsh.
#
# Try it in the current shell:
#     source modules/00-setup/shell-setup.sh
# Make it permanent (pick your shell's rc file):
#     echo "source $PWD/modules/00-setup/shell-setup.sh" >> ~/.bashrc   # or ~/.zshrc
#
# Nothing here is required - every command in the course is written out in
# full (`kubectl ...`) so it also works without these helpers.

# --- tab completion --------------------------------------------------------
if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: make sure the completion system is loaded, then load kubectl's.
  # zsh completes aliases automatically, so `k get po<TAB>` works too.
  if ! command -v compdef >/dev/null 2>&1; then
    autoload -Uz compinit && compinit
  fi
  source <(kubectl completion zsh)
elif [ -n "${BASH_VERSION:-}" ]; then
  # bash: needs the bash-completion package
  #   Debian/Ubuntu/WSL: sudo apt-get install bash-completion
  #   macOS:             brew install bash bash-completion@2  (the system bash 3.2 is too old)
  source <(kubectl completion bash)
  # Teach bash that `k` completes like `kubectl`.
  complete -o default -F __start_kubectl k
fi

# --- aliases ---------------------------------------------------------------
alias k=kubectl

# Print the YAML a command WOULD send, without creating anything:
#   k create deployment web --image=nginx:1.27-alpine $dry > web.yaml
export dry="--dry-run=client -o yaml"

# Quick "where am I?" - current context and namespace.
kctx() {
  printf 'context:   %s\nnamespace: %s\n' \
    "$(kubectl config current-context)" \
    "$(kubectl config view --minify -o jsonpath='{..namespace}' | grep . || echo default)"
}

# Switch the default namespace of the current context:  kns lab-pods
# (`kns` with no argument goes back to `default`).
kns() {
  kubectl config set-context --current --namespace="${1:-default}"
}
