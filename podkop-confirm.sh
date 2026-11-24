#!/bin/sh
set -eu

ui_dir=/www/luci-static/resources/view/podkop
backup_dir=/etc/podkop-luci-confirm
lock_dir=$backup_dir.lock
marker='// mywipvps: Podkop confirmation'

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

patch_ui() {
    case "$1" in
        podkop.js)
            awk -v marker="$marker" '
                /handleSave(Apply)?[[:space:]]*[:(]/ { existing++ }
                /^const EntryPoint = \{$/ {
                    anchors++
                    print
                    print "  " marker
                    print "  handleSave(ev) {"
                    print "    const ru = /^ru(?:[-_]|$)/i.test(document.documentElement.lang);"
                    print "    if (!window.confirm(ru ? \"Сохранить изменения Podkop?\" : \"Save Podkop changes?\")) return;"
                    print "    return view.prototype.handleSave.call(this, ev);"
                    print "  },"
                    print "  handleSaveApply(ev, mode) {"
                    print "    const ru = /^ru(?:[-_]|$)/i.test(document.documentElement.lang);"
                    print "    if (!window.confirm(ru ? \"Применить изменения Podkop? Прокси-соединения могут прерваться.\" :"
                    print "                            \"Apply Podkop changes? Proxy connections may be interrupted.\")) return;"
                    print "    return view.prototype.handleSave.call(this, ev).then(() => ui.changes.apply(mode == \"0\"));"
                    print "  },"
                    next
                }
                /^"require view";$/ { imports++; print; print "\"require ui\";"; next }
                /^"require ui";$/ { existing++ }
                { print }
                END { if (anchors != 1 || imports != 1 || existing) exit 1 }
            ' "$2" ;;
        main.js)
            awk -v marker="$marker" '
                /^async function handleRestart\(\) \{$/ {
                    anchors++
                    print
                    print "  " marker
                    print "  const ru = /^ru(?:[-_]|$)/i.test(document.documentElement.lang);"
                    print "  if (!window.confirm(ru ? \"Перезапустить Podkop? На время перезапуска часть трафика может пойти напрямую.\" :"
                    print "                          \"Restart Podkop? Some traffic may go direct during the restart.\")) return;"
                    next
                }
                /await PodkopShellMethods\.restart\(\);/ { calls++ }
                { print }
                END { if (anchors != 1 || calls != 1) exit 1 }
            ' "$2" ;;
    esac
}

action=${1:-install}
case "$action" in
    install|uninstall) ;;
    *) fail "Usage: sh $0 [install|uninstall]" ;;
esac
[ "$(id -u)" = 0 ] || fail 'Run this script as root on OpenWrt.'
[ -d "$ui_dir" ] || fail 'Podkop LuCI files were not found.'
mkdir "$lock_dir" || fail "Cannot acquire $lock_dir."
staging=
backup_staging=
cleanup() {
    if [ -n "$staging" ]; then
        rm -f "$staging/podkop.js" "$staging/main.js"
        rmdir "$staging"
    fi
    if [ -n "$backup_staging" ]; then
        rm -f "$backup_staging/podkop.js" "$backup_staging/main.js"
        rmdir "$backup_staging"
    fi
    rmdir "$lock_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ "$action" = uninstall ] && [ ! -d "$backup_dir" ]; then
    fail 'No backups found. Reinstall luci-app-podkop if its files were modified.'
fi

staging=$(mktemp -d "$ui_dir/.confirm.XXXXXX")
for file in podkop.js main.js; do
    current=$ui_dir/$file
    original=$current
    if [ -d "$backup_dir" ]; then
        original=$backup_dir/$file
    fi
    [ -f "$current" ] && [ -f "$original" ] || fail "Missing $file or its backup."
    if grep -Fq "$marker" "$original"; then
        fail "Cannot use a modified $file as a backup."
    fi
    cp -p "$current" "$staging/$file"
    patch_ui "$file" "$original" > "$staging/$file" || fail "Unsupported LuCI source in $file."
    if ! cmp -s "$current" "$original" && ! cmp -s "$current" "$staging/$file"; then
        if [ "$action" = install ]; then
            fail "$file changed since installation. Run uninstall, then install again."
        fi
        if grep -Fq "$marker" "$current"; then
            fail "$file has local edits on top of the patch. Restore it manually."
        fi
    fi
done

if [ "$action" = install ]; then
    if [ ! -d "$backup_dir" ]; then
        backup_staging=$(mktemp -d "$backup_dir.XXXXXX")
        cp -p "$ui_dir/podkop.js" "$ui_dir/main.js" "$backup_staging/"
        mv "$backup_staging" "$backup_dir"
        backup_staging=
    fi
    for file in podkop.js main.js; do
        if ! cmp -s "$ui_dir/$file" "$staging/$file"; then
            mv -f "$staging/$file" "$ui_dir/$file"
        fi
    done
    printf '%s\n' 'Podkop confirmations installed. Reload the LuCI page with Ctrl+F5.'
else
    for file in podkop.js main.js; do
        if cmp -s "$ui_dir/$file" "$staging/$file"; then
            cp -p "$backup_dir/$file" "$staging/$file"
            mv -f "$staging/$file" "$ui_dir/$file"
        fi
    done
    backup_staging=$(mktemp -d "$backup_dir.XXXXXX")
    rmdir "$backup_staging"
    mv "$backup_dir" "$backup_staging"
    printf '%s\n' 'Podkop confirmations removed. Reload the LuCI page with Ctrl+F5.'
fi
