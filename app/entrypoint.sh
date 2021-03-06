#!/bin/bash

set -u

# shellcheck source=functions.sh
source /app/functions.sh
DEBUG="$(lc "$DEBUG")"

if [[ ${DEBUG:-} == true ]]; then
  DEBUG=1 && export DEBUG
fi

function check_docker_socket {
    if [[ $DOCKER_HOST == unix://* ]]; then
        socket_file=${DOCKER_HOST#unix://}
        if [[ ! -S $socket_file ]]; then
            echo "Error: you need to share your Docker host socket with a volume at $socket_file" >&2
            echo "Typically you should run your container with: '-v /var/run/docker.sock:$socket_file:ro'" >&2
            exit 1
        fi
    fi
}

function check_writable_directory {
    local dir="$1"
    if [[ $(get_self_cid) ]]; then
        if ! docker_api "/containers/$(get_self_cid)/json" | jq ".Mounts[].Destination" | grep -q "^\"$dir\"$"; then
            echo "Warning: '$dir' does not appear to be a mounted volume."
        fi
    else
        echo "Warning: can't check if '$dir' is a mounted volume without self container ID."
    fi
    if [[ ! -d "$dir" ]]; then
        echo "Error: can't access to '$dir' directory !" >&2
        echo "Check that '$dir' directory is declared as a writable volume." >&2
        exit 1
    fi
    if ! touch "$dir/.check_writable" 2>/dev/null ; then
        echo "Error: can't write to the '$dir' directory !" >&2
        echo "Check that '$dir' directory is export as a writable volume." >&2
        exit 1
    fi
    rm -f "$dir/.check_writable"
}

function check_dh_group {
    # Credits to Steve Kamerman for the background Diffie-Hellman creation logic.
    # https://github.com/jwilder/nginx-proxy/pull/589
    local DHPARAM_BITS="${DHPARAM_BITS:-2048}"
    re='^[0-9]*$'
    if ! [[ "$DHPARAM_BITS" =~ $re ]] ; then
       echo "Error: invalid Diffie-Hellman size of $DHPARAM_BITS !" >&2
       exit 1
    fi

    # If a dhparam file is not available, use the pre-generated one and generate a new one in the background.
    local PREGEN_DHPARAM_FILE="/app/dhparam.pem.default"
    local DHPARAM_FILE="/etc/nginx/certs/dhparam.pem"
    local GEN_LOCKFILE="/tmp/le_companion_dhparam_generating.lock"

    # The hash of the pregenerated dhparam file is used to check if the pregen dhparam is already in use
    local PREGEN_HASH; PREGEN_HASH=$(sha256sum "$PREGEN_DHPARAM_FILE" | cut -d ' ' -f1)
    if [[ -f "$DHPARAM_FILE" ]]; then
        local CURRENT_HASH; CURRENT_HASH=$(sha256sum "$DHPARAM_FILE" | cut -d ' ' -f1)
        if [[ "$PREGEN_HASH" != "$CURRENT_HASH" ]]; then
            # There is already a dhparam, and it's not the default
            set_ownership_and_permissions "$DHPARAM_FILE"
            echo "Info: Custom Diffie-Hellman group found, generation skipped."
            return 0
          fi

        if [[ -f "$GEN_LOCKFILE" ]]; then
            # Generation is already in progress
            return 0
        fi
    fi

    echo "Info: Creating Diffie-Hellman group in the background."
    echo "A pre-generated Diffie-Hellman group will be used for now while the new one
is being created."

    # Put the default dhparam file in place so we can start immediately
    cp "$PREGEN_DHPARAM_FILE" "$DHPARAM_FILE"
    set_ownership_and_permissions "$DHPARAM_FILE"
    touch "$GEN_LOCKFILE"

    # Generate a new dhparam in the background in a low priority and reload nginx when finished (grep removes the progress indicator).
    (
        (
            nice -n +5 openssl dhparam -out "${DHPARAM_FILE}.new" "$DHPARAM_BITS" 2>&1 \
            && mv "${DHPARAM_FILE}.new" "$DHPARAM_FILE" \
            && echo "Info: Diffie-Hellman group creation complete, reloading nginx." \
            && set_ownership_and_permissions "$DHPARAM_FILE" \
            && reload_nginx
        ) | grep -vE '^[\.+]+'
        rm "$GEN_LOCKFILE"
    ) & disown
}

function check_default_account {
    # The default account is now for empty account email
    if [[ -f /etc/acme.sh/default/account.conf ]]; then
        if grep -q ACCOUNT_EMAIL /etc/acme.sh/default/account.conf; then
            sed -i '/ACCOUNT_EMAIL/d' /etc/acme.sh/default/account.conf
        fi
    fi
}

export NGINX_PROXY_CONTAINER_LABEL="${NGINX_PROXY_CONTAINER_LABEL:-com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy}"
export DOCKER_GEN_CONTAINER_LABEL="${DOCKER_GEN_CONTAINER_LABEL:-com.github.jrcs.letsencrypt_nginx_proxy_companion.docker_gen}"

if [[ "$*" == "/bin/bash /app/start.sh" ]]; then
    acmev1_r='acme-(v01\|staging)\.api\.letsencrypt\.org'
    if [[ "${ACME_CA_URI:-}" =~ $acmev1_r ]]; then
        echo "Error: the ACME v1 API is no longer supported by simp_le."
        echo "See https://github.com/zenhack/simp_le/pull/119"
        echo "Please use one of Let's Encrypt ACME v2 endpoints instead."
        exit 1
    fi
    check_docker_socket
    while true; do
        if [[ -z "$(get_nginx_proxy_container)" ]]; then
            echo "Error: can't get nginx-proxy container ID !" >&2
            echo "Check that you are doing one of the following :" >&2
            echo -e "\t- Use the --volumes-from option to mount volumes from the nginx-proxy container." >&2
            echo -e "\t- Set the NGINX_PROXY_CONTAINER env var on the letsencrypt-companion container to the name of the nginx-proxy container." >&2
            echo -e "\t- Label the nginx-proxy container to use with 'com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy'." >&2
            sleep 1
            continue
        fi
        break
    done
    while true; do
        if [[ -z "$(get_docker_gen_container)" ]] && ! is_docker_gen_container "$(get_nginx_proxy_container)"; then
            echo "Error: can't get docker-gen container id !" >&2
            echo "If you are running a three containers setup, check that you are doing one of the following :" >&2
            echo -e "\t- Set the NGINX_DOCKER_GEN_CONTAINER env var on the letsencrypt-companion container to the name of the docker-gen container." >&2
            echo -e "\t- Label the docker-gen container to use with 'com.github.jrcs.letsencrypt_nginx_proxy_companion.docker_gen.'" >&2
            sleep 1
            continue
        fi
        break
    done
    check_writable_directory '/etc/nginx/certs'
    check_writable_directory '/etc/acme.sh'
    check_writable_directory '/usr/share/nginx/html'
    [[ -f /app/letsencrypt_user_data ]] && check_writable_directory '/etc/nginx/conf.d'
    check_dh_group
    reload_nginx
    check_default_account
fi

exec "$@"
