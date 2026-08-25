#!/bin/bash
set -Eeuo pipefail
umask 077

result=${TKL_TEST_RESULT:?TKL_TEST_RESULT is required}
app_password=${TKL_TEST_APP_PASS:?TKL_TEST_APP_PASS is required}
db_password=${TKL_TEST_DB_PASS:?TKL_TEST_DB_PASS is required}
base=https://127.0.0.1
cookie_jar=/tmp/tkl-phplist-cookies.$$
login_page=/tmp/tkl-phplist-login.$$
admin_page=/tmp/tkl-phplist-admin.$$
edit_list_page=/tmp/tkl-phplist-edit-list.$$
list_result=/tmp/tkl-phplist-list-result.$$
new_user_page=/tmp/tkl-phplist-new-user.$$
user_result=/tmp/tkl-phplist-user-result.$$
queue_result=/tmp/tkl-phplist-queue.$$
updater_result_file=/tmp/tkl-phplist-updater.$$
apt_policy=/tmp/tkl-phplist-apt-policy.$$
list_id=
subscriber_id=
list_name=TurnKey-v19-list-$$
subscriber_email=turnkey-v19-$$@example.test
mail_subject="TurnKey phpList v19 mail $$"
step=startup

trap 'rc=$?; printf "phplist-v19-test-failure step=%s line=%s status=%s\n" "$step" "$LINENO" "$rc" >&2; exit "$rc"' ERR

database() {
    mariadb --batch --skip-column-names --user=root \
        --password="$db_password" phplist "$@"
}

html_value() {
    python3 - "$1" "$2" <<'PY'
import re
import sys

page = open(sys.argv[1], encoding="utf-8").read()
match = re.search(sys.argv[2], page)
assert match, f"pattern did not match: {sys.argv[2]}"
print(match.group(1))
PY
}

cleanup() {
    set +e
    if [[ $subscriber_id =~ ^[0-9]+$ ]]; then
        database --execute \
            "DELETE FROM listuser WHERE userid=$subscriber_id; DELETE FROM user WHERE id=$subscriber_id;" \
            >/dev/null 2>&1
    fi
    if [[ $list_id =~ ^[0-9]+$ ]]; then
        database --execute \
            "DELETE FROM listuser WHERE listid=$list_id; DELETE FROM list WHERE id=$list_id;" \
            >/dev/null 2>&1
    fi
    rm -f -- "$cookie_jar" "$login_page" "$admin_page" \
        "$edit_list_page" "$list_result" "$new_user_page" \
        "$user_result" "$queue_result" "$updater_result_file" \
        "$apt_policy"
}
trap cleanup EXIT

step=service-state
systemctl --quiet is-active apache2.service mariadb.service postfix.service \
    cron.service multi-user.target
systemctl --quiet is-enabled apache2.service mariadb.service postfix.service \
    cron.service

step=application-version
installed=$(php -r '
    $source = file_get_contents($argv[1]);
    preg_match("/define\\(\"VERSION\",\"([^\"]+)\"\\)/", $source, $match);
    echo $match[1] ?? "";
' /var/www/phplist/admin/init.php)
test "$installed" = 3.7.0
metadata_version=$(sed -nE 's/^VERSION=([0-9]+(\.[0-9]+)+)$/\1/p' \
    /usr/share/turnkey-phplist/VERSION)
test "$metadata_version" = "$installed"
installed_digest=$(awk -v archive="phplist-$installed.zip" \
    '$2 == archive { print $1 }' \
    /usr/share/turnkey-phplist/release.sha256)
test "$installed_digest" = \
    0b1c2eae6a7fd617d18438d97d47714b4cbfdf3e6b2abab8a154e17d28ec89de

step=packages-and-modules
php_package=$(dpkg-query -W -f='${Version}' php)
mariadb_package=$(dpkg-query -W -f='${Version}' mariadb-server)
apache_package=$(dpkg-query -W -f='${Version}' apache2)
postfix_package=$(dpkg-query -W -f='${Version}' postfix)
cron_package=$(dpkg-query -W -f='${Version}' cron)
php_modules=$(php -m)
for module in curl gd gettext json mbstring mysqli openssl simplexml xml zip; do
    grep -Fxiq "$module" <<<"$php_modules"
done
dpkg-query -W webmin-apache webmin-mysql >/dev/null

step=administrator-login
curl --insecure --fail --silent --show-error "$base/" >"$list_result"
grep -qi 'phpList' "$list_result"
curl --insecure --fail --silent --show-error \
    --cookie-jar "$cookie_jar" "$base/admin/" >"$login_page"
grep -Fq 'Please login to continue' "$login_page"
curl --insecure --fail --silent --show-error --location \
    --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
    --data-urlencode 'page=home' \
    --data-urlencode 'login=admin' \
    --data-urlencode "password=$app_password" \
    --data-urlencode 'process=Continue' \
    "$base/admin/" >"$admin_page"
grep -Fq 'id="logout"' "$admin_page"
grep -Fq '>Dashboard<' "$admin_page"
session_token=$(html_value "$admin_page" 'tk=([0-9a-f]{32})')

step=list-roundtrip
curl --insecure --fail --silent --show-error \
    --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
    "$base/admin/?page=editlist&tk=$session_token" >"$edit_list_page"
form_token=$(html_value "$edit_list_page" \
    'name="formtoken" value="([0-9a-f]+)"')
curl --insecure --fail --silent --show-error --location \
    --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
    --data-urlencode "formtoken=$form_token" \
    --data-urlencode "listname=$list_name" \
    --data-urlencode 'active=1' \
    --data-urlencode 'listorder=0' \
    --data-urlencode 'owner=1' \
    --data-urlencode 'description=TurnKey v19 disposable list' \
    --data-urlencode 'addnewlist=Save' \
    "$base/admin/?page=editlist&tk=$session_token" >"$list_result"
list_id=$(database --execute \
    "SELECT id FROM list WHERE name='$list_name' AND active=1 AND description='TurnKey v19 disposable list';")
[[ $list_id =~ ^[0-9]+$ ]]
curl --insecure --fail --silent --show-error \
    --cookie "$cookie_jar" \
    "$base/admin/?page=list&tk=$session_token" >"$list_result"
grep -Fq "$list_name" "$list_result"
grep -Fq 'TurnKey v19 disposable list' "$list_result"

step=subscriber-roundtrip
curl --insecure --fail --silent --show-error \
    --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
    "$base/admin/?page=user&tk=$session_token" >"$new_user_page"
form_token=$(html_value "$new_user_page" \
    'name="formtoken" value="([0-9a-f]+)"')
curl --insecure --fail --silent --show-error --location \
    --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
    --data-urlencode "formtoken=$form_token" \
    --data-urlencode "email=$subscriber_email" \
    --data-urlencode 'change=Continue' \
    "$base/admin/?page=user&tk=$session_token" >"$new_user_page"
subscriber_id=$(database --execute \
    "SELECT id FROM user WHERE email='$subscriber_email';")
[[ $subscriber_id =~ ^[0-9]+$ ]]
form_token=$(html_value "$new_user_page" \
    'name="formtoken" value="([0-9a-f]+)"')
curl --insecure --fail --silent --show-error --location \
    --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
    --data-urlencode "formtoken=$form_token" \
    --data-urlencode "id=$subscriber_id" \
    --data-urlencode "email=$subscriber_email" \
    --data-urlencode 'confirmed=1' \
    --data-urlencode 'htmlemail=1' \
    --data-urlencode 'rssfrequency=' \
    --data-urlencode 'disabled=0' \
    --data-urlencode 'extradata=' \
    --data-urlencode 'foreignkey=' \
    --data-urlencode 'subscribe[]=-1' \
    --data-urlencode "subscribe[]=$list_id" \
    --data-urlencode 'change=Save changes' \
    "$base/admin/?page=user&id=$subscriber_id&tk=$session_token" \
    >"$user_result"
grep -Fq "Subscriber added to list $list_name" "$user_result"
curl --insecure --fail --silent --show-error \
    --cookie "$cookie_jar" \
    "$base/admin/?page=user&id=$subscriber_id&tk=$session_token" \
    >"$user_result"
grep -Fq "$subscriber_email" "$user_result"
grep -Fq "$list_name" "$user_result"
database --execute \
    "SELECT CONCAT(u.email, '|', u.confirmed, '|', l.name) FROM user u JOIN listuser lu ON lu.userid=u.id JOIN list l ON l.id=lu.listid WHERE u.id=$subscriber_id AND l.id=$list_id;" |
    grep -Fxq "$subscriber_email|1|$list_name"

step=scheduler
test "$(stat -c '%U:%G %a' /etc/cron.d/phplist)" = 'root:root 644'
grep -Fxq \
    '*/5 * * * * root /usr/local/bin/phplist -pprocessqueue >/dev/null 2>&1' \
    /etc/cron.d/phplist
/usr/local/bin/phplist -pprocessqueue >"$queue_result"
grep -Fq 'Finished, All done' "$queue_result"

step=mail
test "$(postconf -h inet_interfaces)" = localhost
printf 'From: acceptance@localhost\r\nTo: root@localhost\r\nSubject: %s\r\n\r\nmail-ok\r\n' \
    "$mail_subject" |
    curl --silent --show-error --fail --url smtp://127.0.0.1 \
        --mail-from acceptance@localhost --mail-rcpt root@localhost \
        --upload-file -
for _ in 1 2 3 4 5; do
    grep -Fq "$mail_subject" /var/mail/root 2>/dev/null && break
    sleep 1
done
grep -Fq "$mail_subject" /var/mail/root

step=management-endpoints
curl --insecure --fail --silent --show-error --head \
    https://127.0.0.1:12321/ >/dev/null
curl --insecure --fail --silent --show-error --head \
    https://127.0.0.1:12322/ >/dev/null

step=updater
code_before=$(sha256sum /var/www/phplist/admin/init.php \
    /var/www/phplist/config/config.php)
/usr/local/sbin/turnkey-phplist-update --check >"$updater_result_file"
code_after=$(sha256sum /var/www/phplist/admin/init.php \
    /var/www/phplist/config/config.php)
test "$code_after" = "$code_before"
grep -Fxq "installed_version=$installed" "$updater_result_file"
grep -Fxq 'updater_channel=phpList official stable' "$updater_result_file"
available=$(sed -n 's/^available_version=//p' "$updater_result_file")
artifact=$(sed -n 's/^artifact_sha256=//p' "$updater_result_file")
status=$(sed -n 's/^status=//p' "$updater_result_file")
[[ $available =~ ^[0-9]+(\.[0-9]+)+$ ]]
[[ $artifact =~ ^[0-9a-f]{64}$ ]]
[[ $status == up-to-date || $status == update-available ]]
dpkg --compare-versions "$available" ge "$installed"

step=apt
before="$php_package|$mariadb_package|$apache_package|$postfix_package|$cron_package"
apt-get update >/dev/null
for package in php mariadb-server apache2 postfix cron; do
    apt-cache policy "$package" >"$apt_policy"
    candidate=$(awk '/Candidate:/ { print $2 }' "$apt_policy")
    test -n "$candidate"
    test "$candidate" != '(none)'
    grep -Eq 'trixie|deb13' "$apt_policy"
done
after="$(dpkg-query -W -f='${Version}' php)|$(dpkg-query -W -f='${Version}' mariadb-server)|$(dpkg-query -W -f='${Version}' apache2)|$(dpkg-query -W -f='${Version}' postfix)|$(dpkg-query -W -f='${Version}' cron)"
test "$after" = "$before"
grep -Rqs '^Suites: trixie' /etc/apt/sources.list.d
! grep -Rqi bookworm /etc/apt/sources.list.d

step=result
cat >"$result" <<EOF
package_source=Official phpList $installed SourceForge release; Debian Trixie APT packages for PHP, MariaDB, Apache, Postfix and cron; TurnKey APT packages for Webmin and Adminer
installed_version=phpList $installed; php $php_package; mariadb-server $mariadb_package; apache2 $apache_package; postfix $postfix_package; cron $cron_package
runtime_checks=normal init; Apache, MariaDB, Postfix and cron active; phpList administrator HTTPS login; list and subscriber create/read roundtrip; MariaDB relationship readback and cleanup; scheduled empty queue processing; loopback SMTP delivery; Webmin and Adminer endpoints
updater_command=turnkey-phplist-update --check; apt-get update; apt-cache policy php mariadb-server apache2 postfix cron
updater_result=official stable release $available and SHA-256 $artifact verified; status $status; installed application and package versions unchanged
updater_channel=phpList official stable release channel; Debian and TurnKey Trixie APT repositories
integrity_evidence=official SourceForge SHA-256 manifest matched the installed phpList archive digest $installed_digest; updater downloaded and verified the eligible official artifact; APT accepted signed Trixie repository metadata
EOF
