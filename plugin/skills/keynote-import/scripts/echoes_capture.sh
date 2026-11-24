#!/bin/sh
# Open a temporary Echoes window, render a przn deck in it, and save one
# PNG per slide.
#
# usage: echoes_capture.sh DECK.md OUTDIR [FONT_SIZE]
#
# The window reuses the size of the user's last Echoes window. FONT_SIZE
# changes how many rows and columns fit; without it the user's saved font
# size applies. Echoes reads its config from $HOME, so the window runs with
# a throwaway HOME to leave the user's echoes.conf untouched.
#
# Echoes is found in this order:
#   1. $ECHOES_ROOT (a checkout of https://github.com/amatsuda/echoes)
#   2. the checkout that Echoes.app points at (`echoes install`)
#   3. the installed echoes gem
set -e

if [ $# -lt 2 ]; then
  echo "usage: $0 DECK.md OUTDIR [FONT_SIZE]" >&2
  exit 1
fi

deck=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$(mkdir -p "$2" && cd "$2" && pwd)
font=$3
scripts=$(cd "$(dirname "$0")" && pwd)

echoes_root=$ECHOES_ROOT
if [ -z "$echoes_root" ]; then
  for app in "$HOME/Applications/Echoes.app" /Applications/Echoes.app; do
    launcher="$app/Contents/MacOS/Echoes"
    [ -f "$launcher" ] || continue
    # `echoes install` writes a launcher that execs the one inside the checkout
    target=$(sed -n 's/^exec "\(.*\)"$/\1/p' "$launcher")
    [ -n "$target" ] || target=$launcher
    candidate=$(cd "$(dirname "$target")/../../.." && pwd)
    if [ -f "$candidate/lib/echoes.rb" ]; then
      echoes_root=$candidate
      break
    fi
  done
fi

# Resolve the interpreters before HOME changes: version-manager shims
# (rbenv, mise, ...) look their versions up under the real HOME.
if [ -n "$echoes_root" ]; then
  echoes_ruby=$(cd "$echoes_root" && ruby -e 'print RbConfig.ruby')
  load_path="-I$echoes_root/lib"
else
  echoes_ruby=$(ruby -e 'print RbConfig.ruby')
  load_path=
  if ! "$echoes_ruby" -e 'require "echoes"' 2>/dev/null; then
    echo "Echoes not found. Set ECHOES_ROOT to an Echoes checkout or install the echoes gem." >&2
    exit 1
  fi
fi

if [ -f "$(dirname "$deck")/Gemfile" ]; then
  deck_ruby="bundle exec ruby"
else
  deck_ruby="ruby"
fi

fake_home=$(mktemp -d)
mkdir -p "$fake_home/.config/echoes"
runner="$fake_home/run.sh"
cat > "$runner" <<RUNNER
#!/bin/sh
export HOME="$HOME"
cd "$(dirname "$deck")"
$deck_ruby "$scripts/capture_slides.rb" "$deck" "$out" 2> "$out/capture.log"
touch "$out/done"
RUNNER
chmod +x "$runner"
# Echoes saves a capture only under its capture_directory
printf "shell '%s'\ncapture_directory '%s'\n" "$runner" "$out" > "$fake_home/.config/echoes/echoes.conf"

rm -f "$out/done"
# shellcheck disable=SC2086
FONT="$font" HOME="$fake_home" "$echoes_ruby" $load_path \
  -e 'require "echoes"; f = ENV["FONT"].to_s; Echoes::GUI.new(**(f.empty? ? {} : {font_size: f.to_f})).run' \
  > "$out/echoes.log" 2>&1 &
pid=$!
waited=0
while [ ! -f "$out/done" ] && [ $waited -lt 90 ] && kill -0 $pid 2>/dev/null; do
  sleep 1
  waited=$((waited + 1))
done
sleep 1
kill $pid 2>/dev/null || true
/bin/rm -rf "$fake_home"

if [ ! -f "$out/done" ]; then
  echo "Capture did not finish. See $out/echoes.log and $out/capture.log." >&2
  exit 1
fi
echo "grid: $(cat "$out/size.txt")"
ls "$out"
