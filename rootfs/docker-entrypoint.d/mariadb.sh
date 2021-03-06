# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
    case "$arg" in
        -'?'|--help|--print-defaults|-V|--version)
            wantHelp=1
            break
            ;;
    esac
done

_check_config() {
    toRun="$@ --verbose --help --log-bin-index="$(mktemp -u)
    if ! errors="$($toRun 2>&1 >/dev/null)"; then
        cat >&2 <<-EOM
ERROR: mysqld failed while attempting to check config
command was: "$toRun"
$errors
EOM
        exit 1
    fi
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
_get_config() {
    local conf="$1"; shift
    "$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null \
    awk '$1 == "'"$conf"'" && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
    # match "datadir      /some/path with/spaces in/it here" but not "--xyz=abc\n     datadir (xyz)"
}

_datadir() {
    $@ --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | awk '$1 == "datadir" { print $2; exit }'
}

if [ "$1" = 'mysqld' ] && [ -z "$wantHelp" ]; then
    # still need to check config, container may have started with --user
    _check_config "$@"
    # Get config
    DATADIR="$(_datadir "$@")"

    if [ ! -d "$DATADIR/mysql" ]; then
        if [ -z "$MYSQL_ROOT_PASSWORD" ] && [ -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ] && [ -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
            echo >&2 'error: database is uninitialized and password option is not specified '
            echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
            exit 1
        fi

        mkdir -p "$DATADIR"
        chown -R mysql:mysql "$DATADIR"

        echo 'Initializing database'
        mysql_install_db --user=mysql --datadir="$DATADIR" --rpm
        echo 'Database initialized'

        /sbin/tini -s -g -- su-exec mysql $@ --skip-networking &
        pid="$!"

        mysql="mysql --protocol=socket -uroot"

        for i in $(seq 30 -1 0); do
            if echo 'SELECT 1' | $mysql &> /dev/null; then
                break
            fi
            echo 'MySQL init process in progress...'
            sleep 1
        done
        if [ "$i" = 0 ]; then
            echo >&2 'MySQL init process failed.'
            exit 1
        fi

        if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
            # sed is for https://bugs.mysql.com/bug.php?id=20545
            mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | $mysql mysql
        fi

        if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
            MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
            echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
        fi

        $mysql <<-EOSQL
-- What's done in this file shouldn't be replicated
--  or products like mysql-fabric won't work
SET @@SESSION.SQL_LOG_BIN=0;

DELETE FROM mysql.user ;
CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
DROP DATABASE IF EXISTS test ;
FLUSH PRIVILEGES ;
EOSQL

        if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
            mysql="$mysql -p${MYSQL_ROOT_PASSWORD}"
        fi

        . /bin/file_env

        # one line url configuration
        file_env 'MYSQL_URL'
        file_env 'DATABASE_URL'

        file_env 'MYSQL_DATABASE' "$(parse_url "${MYSQL_URL:-$DATABASE_URL}" path)"
        if [ "$MYSQL_DATABASE" ]; then
            echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET utf8 COLLATE utf8_general_ci;" | $mysql
            mysql="$mysql $MYSQL_DATABASE"
        fi

        file_env 'MYSQL_USER' "$(parse_url "${MYSQL_URL:-$DATABASE_URL}" user)"
        file_env 'MYSQL_PASSWORD' "$(parse_url "${MYSQL_URL:-$DATABASE_URL}" pass)"
        if [ "$MYSQL_USER" ] && [ "$MYSQL_PASSWORD" ]; then
            echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | $mysql

            if [ "$MYSQL_DATABASE" ]; then
                echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | $mysql
            fi

            echo 'FLUSH PRIVILEGES ;' | $mysql
        fi

        echo
        for f in /docker-entrypoint-initdb.d/*; do
            case "$f" in
                *.sh)     echo "$0: running $f"; . "$f" ;;
                *.sql)    echo "$0: running $f"; $mysql < "$f"; echo ;;
                *.sql.gz) echo "$0: running $f"; gunzip -c "$f" | $mysql; echo ;;
            esac
            echo
        done

        if ! kill -s TERM "$pid" || ! wait "$pid"; then
            echo >&2 'MySQL init process failed.'
            exit 1
        fi

        echo
        echo 'MySQL init process done. Ready for start up.'
        echo
    fi
fi
