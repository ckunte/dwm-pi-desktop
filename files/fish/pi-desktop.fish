fish_add_path -m $HOME/.local/bin
set -g fish_greeting
set -gx GPG_TTY (tty)

if status is-interactive; and type -q starship
    starship init fish | source
end

# y: yazi that leaves the shell in the directory you quit it in.
function y
    set tmp (mktemp -t "yazi-cwd.XXXXXX")
    command yazi $argv --cwd-file="$tmp"
    if read -z cwd <"$tmp"; and [ "$cwd" != "$PWD" ]; and test -d "$cwd"
        builtin cd -- "$cwd"
    end
    command rm -f -- "$tmp"
end
