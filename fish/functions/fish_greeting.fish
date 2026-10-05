function fish_greeting
    # ── Colors ──
    set -l dim (set_color brblack)
    set -l blue (set_color brblue)
    set -l green (set_color brgreen)
    set -l yellow (set_color bryellow)
    set -l red (set_color brred)
    set -l bold (set_color --bold normal)
    set -l r (set_color normal)

    # ── Gather info ──
    set -l dt (date "+%a %d. %b, %H:%M")
    set -l os_ver (sw_vers -productVersion 2>/dev/null)
    test -z "$os_ver"; and set os_ver "?"
    set -l mem_gb (math --scale=0 (sysctl -n hw.memsize 2>/dev/null; or echo 0) / 1073741824)

    # Uptime
    set -l up (uptime | string replace -r '.*up\s+' '' | string replace -r ',\s*\d+ users?.*' '' | string trim)

    # Disk usage with color coding
    set -l disk (df -h / | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')
    set -l pct (df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')
    set -l dc $green
    if test "$pct" -gt 80 2>/dev/null
        set dc $red
    else if test "$pct" -gt 60 2>/dev/null
        set dc $yellow
    end

    # ── Render ──
    echo
    printf "  %s%s%s  %s·  macOS %s · %s · %sGB RAM%s\n" $bold $dt $r $dim $os_ver (uname -m) $mem_gb $r
    printf "  %s─────────────────────────────────────────────%s\n" $dim $r
    printf "  %s▸ %suptime  %s%s\n" $blue $dim $r "$up"
    printf "  %s▸ %sdisk    %s%s\n" $dc $dim $r "$disk"

    # Docker (nur wenn Container laufen): Wert vom letzten Start, docker ps läuft im Hintergrund
    if command -q docker
        set -l cache ~/.cache/fish/docker_running
        set -l cnt (cat $cache 2>/dev/null)
        if test -n "$cnt"; and test "$cnt" -gt 0
            printf "  %s▸ %sdocker  %s%s running%s\n" $blue $dim $green $cnt $r
        end
        mkdir -p (path dirname $cache)
        fish --no-config -c "docker ps -q 2>/dev/null | count > $cache" &
        disown $last_pid
    end

    printf "  %s─────────────────────────────────────────────%s\n" $dim $r
    echo
end