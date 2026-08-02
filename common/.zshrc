HISTFILE=/home/ubuntu/.history/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory
unsetopt HIST_SAVE_BY_COPY

autoload -Uz vcs_info
precmd() { vcs_info }

zstyle ':vcs_info:git:*' formats '%b '

setopt PROMPT_SUBST
alias ll='ls -lah'

## CUSTOM FUNCTIONS
function gitpush() {
  git add .
  git commit -m "${1}"
  git push origin 
}

if [ -f $HOME/.zshrc2 ]; then
  echo "{zshenv} Setting RC2 up with ZSH."
  source "$HOME/.zshrc2"
fi
PROMPT='%F{green}%*%f %F{blue}%~%f %F{red}${vcs_info_msg_0_}%f$ '

  git config --global user.email "5518783+jay-dizzale@users.noreply.github.com"
  git config --global user.name "jay-dizzale"

# Set Global Editor
git config --global init.defaultBranch main
git config --global core.editor vim
git config --global color.branch auto
git config --global color.diff auto
git config --global color.interactive auto
git config --global color.status auto
git config --global color.grep auto
git config --global --add safe.directory '*'
git config --global --add --bool push.autoSetupRemote true

export PATH="$HOME/.local/bin:$PATH"

[ -t 1 ] && motd
