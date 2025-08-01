#!/usr/bin/env bats

set -u

setup_file() {
    load "../lib/setup_file.sh"
}

teardown_file() {
    load "../lib/teardown_file.sh"
}

setup() {
    load "../lib/setup.sh"
    load "../lib/bats-file/load.bash"
    ./instance-data load
}

teardown() {
    ./instance-crowdsec stop
}

#----------

@test "crowdsec (usage)" {
    rune -0 wait-for --out "Usage of " "$CROWDSEC" -h
    rune -0 wait-for --out "Usage of " "$CROWDSEC" --help
}

@test "crowdsec (unknown flag)" {
    rune -0 wait-for --err "flag provided but not defined: -foobar" "$CROWDSEC" --foobar
}

@test "crowdsec (unknown argument)" {
    rune -0 wait-for --err "argument provided but not defined: trololo" "$CROWDSEC" trololo
}

@test "crowdsec -version" {
    rune -0 "$CROWDSEC" -version
    assert_output --partial "version:"
}

@test "crowdsec (no api and no agent)" {
    rune -0 wait-for \
        --err "you must run at least the API Server or crowdsec" \
        "$CROWDSEC" -no-api -no-cs
}

@test "crowdsec - print error on exit" {
    # errors that cause program termination are printed to stderr, not only logs
    config_set '.db_config.type="meh"'
    rune -1 "$CROWDSEC"
    assert_stderr --partial "unable to create database client: unknown database type 'meh'"
}

@test "crowdsec - default logging configuration (empty/missing common section)" {
    config_set '.common={}'
    rune -0 wait-for \
        --err "Starting processing data" \
        "$CROWDSEC"
    refute_output

    config_set 'del(.common)'
    rune -0 wait-for \
        --err "Starting processing data" \
        "$CROWDSEC"
    refute_output
}

@test "crowdsec - log format" {
    # fail early
    config_disable_lapi
    config_disable_agent

    config_set '.common.log_media="stdout"'

    config_set '.common.log_format=""'
    rune -0 wait-for --err "you must run at least the API Server or crowdsec" "$CROWDSEC"
    assert_stderr --partial 'level=fatal msg="you must run at least the API Server or crowdsec"'

    config_set '.common.log_format="text"'
    rune -0 wait-for --err "you must run at least the API Server or crowdsec" "$CROWDSEC"
    assert_stderr --partial 'level=fatal msg="you must run at least the API Server or crowdsec"'

    config_set '.common.log_format="json"'
    rune -0 wait-for --err "you must run at least the API Server or crowdsec" "$CROWDSEC"
    rune -0 jq -c 'select(.msg=="you must run at least the API Server or crowdsec") | .level' <(stderr | grep "^{")
    assert_output '"fatal"'

    # If log_media='file', a hook to stderr is added only for fatal messages,
    # with a predefined formatter (level + msg, no timestamp, ignore log_format)

    config_set '.common.log_media="file"'

    config_set '.common.log_format="text"'
    rune -0 wait-for --err "you must run at least the API Server or crowdsec" "$CROWDSEC"
    assert_stderr --regexp 'FATAL.* you must run at least the API Server or crowdsec$'

    config_set '.common.log_format="json"'
    rune -0 wait-for --err "you must run at least the API Server or crowdsec" "$CROWDSEC"
    assert_stderr --regexp 'FATAL.* you must run at least the API Server or crowdsec$'
}

@test "crowdsec - pass log level flag to apiserver" {
    LOCAL_API_CREDENTIALS=$(config_get '.api.client.credentials_path')
    config_set "$LOCAL_API_CREDENTIALS" '.password="badpassword"'

    config_set '.common.log_media="stdout"'
    rune -1 "$CROWDSEC"

    # info
    assert_stderr --partial "/v1/watchers/login"
    # fatal
    assert_stderr --partial "incorrect Username or Password"

    config_set '.common.log_media="stdout"'
    rune -1 "$CROWDSEC" -error

    refute_stderr --partial "/v1/watchers/login"
}

@test "CS_LAPI_SECRET not strong enough" {
    CS_LAPI_SECRET=foo rune -1 wait-for "$CROWDSEC"
    assert_stderr --partial "api server init: unable to run local API: controller init: CS_LAPI_SECRET not strong enough"
}

@test "crowdsec - reload" {
    # we test that reload works as intended with the agent enabled

    logfile="$(config_get '.common.log_dir')/crowdsec.log"

    rune -0 truncate -s0 "$logfile"

    rune -0 ./instance-crowdsec start-pid
    PID="$output"

    sleep .5
    rune -0 kill -HUP "$PID"

    sleep 5
    rune -0 ps "$PID"

    assert_file_contains "$logfile" "Reload is finished"
}

@test "crowdsec - reload (change of logfile, disabled agent)" {
    # we test that reload works as intended with the agent disabled
    # and that we can change the log configuration

    logdir1=$(TMPDIR="$BATS_TEST_TMPDIR" mktemp -u)
    log_old="${logdir1}/crowdsec.log"
    config_set ".common.log_dir=\"${logdir1}\""

    rune -0 ./instance-crowdsec start-pid
    PID="$output"

    sleep .5

    assert_file_exists "$log_old"
    assert_file_contains "$log_old" "Starting processing data"

    logdir2=$(TMPDIR="$BATS_TEST_TMPDIR" mktemp -u)
    log_new="${logdir2}/crowdsec.log"
    config_set ".common.log_dir=\"${logdir2}\""

    config_disable_agent

    sleep 2

    rune -0 kill -HUP "$PID"

    for ((i=0; i<10; i++)); do
        sleep 1
        grep -q "serve: shutting down api server" <"$log_old" && break
    done

    echo "waited $i seconds"

    echo
    echo "OLD LOG"
    echo
    ls -la "$log_old" || true
    cat "$log_old" || true

    assert_file_contains "$log_old" "SIGHUP received, reloading"
    assert_file_contains "$log_old" "Crowdsec engine shutting down"
    assert_file_contains "$log_old" "Killing parser routines"
    assert_file_contains "$log_old" "Bucket routine exiting"
    assert_file_contains "$log_old" "serve: shutting down api server"

    sleep 2

    assert_file_exists "$log_new"

    for ((i=0; i<10; i++)); do
        sleep 1
        grep -q "Reload is finished" <"$log_new" && break
    done

    echo "waited $i seconds"

    echo
    echo "NEW LOG"
    echo
    ls -la "$log_new" || true
    cat "$log_new" || true

    assert_file_contains "$log_new" "CrowdSec Local API listening on 127.0.0.1:8080"
    assert_file_contains "$log_new" "Reload is finished"

    rune -0 ./instance-crowdsec stop
}

# TODO: move acquisition tests to test/bats/crowdsec-acquisition.bats

@test "crowdsec (error if the acquisition_path file is defined but missing)" {
    ACQUIS_YAML=$(config_get '.crowdsec_service.acquisition_path')
    rm -f "$ACQUIS_YAML"

    rune -1 wait-for "$CROWDSEC"
    assert_stderr --partial "acquis.yaml: no such file or directory"
}

@test "crowdsec (error if acquisition_path is not defined and acquisition_dir is empty)" {
    ACQUIS_YAML=$(config_get '.crowdsec_service.acquisition_path')
    rm -f "$ACQUIS_YAML"
    config_set '.crowdsec_service.acquisition_path=""'

    ACQUIS_DIR=$(config_get '.crowdsec_service.acquisition_dir')
    rm -rf "$ACQUIS_DIR"

    config_set '.common.log_media="stdout"'
    rune -1 wait-for "$CROWDSEC"
    # check warning
    assert_stderr --partial "no acquisition file found"
    assert_stderr --partial "crowdsec init: while loading acquisition config: no datasource enabled"
}

@test "crowdsec (error if acquisition_path and acquisition_dir are not defined)" {
    ACQUIS_YAML=$(config_get '.crowdsec_service.acquisition_path')
    rm -f "$ACQUIS_YAML"
    config_set '.crowdsec_service.acquisition_path=""'

    ACQUIS_DIR=$(config_get '.crowdsec_service.acquisition_dir')
    rm -rf "$ACQUIS_DIR"
    config_set '.crowdsec_service.acquisition_dir=""'

    config_set '.common.log_media="stdout"'
    rune -1 wait-for "$CROWDSEC"
    # check warning
    assert_stderr --partial "no acquisition_path or acquisition_dir specified"
    assert_stderr --partial "crowdsec init: while loading acquisition config: no datasource enabled"
}

@test "crowdsec (no error if acquisition_path is empty string but acquisition_dir is not empty)" {
    config_set '.common.log_media="stdout"'

    ACQUIS_YAML=$(config_get '.crowdsec_service.acquisition_path')
    config_set '.crowdsec_service.acquisition_path=""'

    ACQUIS_DIR=$(config_get '.crowdsec_service.acquisition_dir')
    mkdir -p "$ACQUIS_DIR"
    mv "$ACQUIS_YAML" "$ACQUIS_DIR"/foo.yaml

    rune -0 wait-for \
        --err "Starting processing data" \
        "$CROWDSEC"

    # now, if foo.yaml is empty instead, there won't be valid datasources.

    cat /dev/null >"$ACQUIS_DIR"/foo.yaml

    rune -1 wait-for "$CROWDSEC"
    assert_stderr --partial "crowdsec init: while loading acquisition config: no datasource enabled"
}

@test "crowdsec (datasource not built)" {
    config_set '.common.log_media="stdout"'

    # a datasource cannot run - it's not built in the log processor executable

    ACQUIS_DIR=$(config_get '.crowdsec_service.acquisition_dir')
    mkdir -p "$ACQUIS_DIR"
    cat >"$ACQUIS_DIR"/foo.yaml <<-EOT
	source: journalctl
	journalctl_filter:
	 - "_SYSTEMD_UNIT=ssh.service"
	labels:
	  type: syslog
	EOT

    #shellcheck disable=SC2016
    rune -1 wait-for \
        --err "crowdsec init: while loading acquisition config: in file $ACQUIS_DIR/foo.yaml (position: 0) - data source journalctl is not built in this version of crowdsec" \
        env PATH='' "$CROWDSEC".min

    # auto-detection of journalctl_filter still works
    cat >"$ACQUIS_DIR"/foo.yaml <<-EOT
        source: whatever
	journalctl_filter:
	 - "_SYSTEMD_UNIT=ssh.service"
	labels:
	  type: syslog
	EOT

    #shellcheck disable=SC2016
    rune -1 wait-for \
        --err "crowdsec init: while loading acquisition config: in file $ACQUIS_DIR/foo.yaml (position: 0) - data source journalctl is not built in this version of crowdsec" \
        env PATH='' "$CROWDSEC".min
}

@test "crowdsec (disabled datasource)" {
    if is_package_testing; then
        # we can't hide journalctl in package testing
        # because crowdsec is run from systemd
        skip "n/a for package testing"
    fi

    config_set '.common.log_media="stdout"'

    # a datasource cannot run - missing journalctl command

    ACQUIS_DIR=$(config_get '.crowdsec_service.acquisition_dir')
    mkdir -p "$ACQUIS_DIR"
    cat >"$ACQUIS_DIR"/foo.yaml <<-EOT
	source: journalctl
	journalctl_filter:
	 - "_SYSTEMD_UNIT=ssh.service"
	labels:
	  type: syslog
	EOT

    #shellcheck disable=SC2016
    rune -0 wait-for \
        --err 'datasource '\''journalctl'\'' is not available: exec: \\"journalctl\\": executable file not found in ' \
        env PATH='' "$CROWDSEC"

    # if all datasources are disabled, crowdsec should exit

    ACQUIS_YAML=$(config_get '.crowdsec_service.acquisition_path')
    rm -f "$ACQUIS_YAML"
    config_set '.crowdsec_service.acquisition_path=""'

    rune -1 wait-for env PATH='' "$CROWDSEC"
    assert_stderr --partial "crowdsec init: while loading acquisition config: no datasource enabled"
}

@test "crowdsec -t (error in acquisition file)" {
    # we can verify the acquisition configuration without running crowdsec
    ACQUIS_YAML=$(config_get '.crowdsec_service.acquisition_path')
    config_set "$ACQUIS_YAML" 'del(.filenames)'

    # if filenames are missing, it won't be able to detect source type
    config_set "$ACQUIS_YAML" '.source="file"'
    rune -1 wait-for "$CROWDSEC"
    assert_stderr --partial "while configuring datasource of type file from $ACQUIS_YAML (position 0): no filename or filenames configuration provided"

    config_set "$ACQUIS_YAML" '.filenames=["file.log"]'
    config_set "$ACQUIS_YAML" '.meh=3'
    rune -1 wait-for "$CROWDSEC"
    assert_stderr --partial "crowdsec init: while loading acquisition config: while configuring datasource of type file from $ACQUIS_YAML (position 0): cannot parse FileAcquisition configuration: [5:1] unknown field \"meh\""
}
