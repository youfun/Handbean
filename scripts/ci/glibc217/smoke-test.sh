#!/usr/bin/env bash
set -euo pipefail

archive=${1:?release archive is required}
work_root=${2:?work directory is required}
openssl=${3:?pinned OpenSSL executable is required}
port=${HANDBEAN_SMOKE_PORT:-5027}
relay_port=${HANDBEAN_SMOKE_RELAY_PORT:-17653}

rm -rf "$work_root"
mkdir -p "$work_root/release" "$work_root/home" "$work_root/data"
tar -C "$work_root/release" -xzf "$archive"

release="$work_root/release"
sys_config=$(find "$release/releases" -mindepth 2 -maxdepth 2 -name sys.config -print -quit)
test -n "$sys_config"
grep -Fq '{chrome_relay_port,17688}' "$sys_config"
sed -i "s/{chrome_relay_port,17688}/{chrome_relay_port,$relay_port}/" "$sys_config"
export PATH=/usr/bin:/bin
unset LD_LIBRARY_PATH ERL_LIBS ERL_AFLAGS ERL_ZFLAGS MIX_HOME HEX_HOME CARGO_HOME RUSTUP_HOME ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR
export HOME="$work_root/home"
export PHX_SERVER=true
export PORT="$port"
export PHX_HOST=localhost
export DATABASE_PATH="$work_root/data/handbean.db"
export HANDBEAN_WORKSPACES_FILE="$work_root/data/workspaces.json"
export HANDBEAN_ALLOW_HTTP=1
export SECRET_KEY_BASE=glibc217-ci-runtime-validation-secret-key-base-0123456789-abcdefghijklmnopqrstuvwxyz
export RELEASE_NODE=handbean_glibc217_smoke
export RELEASE_COOKIE=handbean_glibc217_smoke_cookie

release_pid=""
tls_pid=""
cleanup() {
  if [[ -n "$tls_pid" ]]; then
    kill "$tls_pid" 2>/dev/null || true
    wait "$tls_pid" 2>/dev/null || true
  fi
  if [[ -n "$release_pid" ]]; then
    if kill -0 "$release_pid" 2>/dev/null; then
      "$release/bin/handbean" stop >/dev/null 2>&1 || true
    fi
    kill "$release_pid" 2>/dev/null || true
    wait "$release_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo '== clean PATH =='
for command_name in erl elixir mix; do
  if command -v "$command_name" >/dev/null 2>&1; then
    echo "unexpected system tool: $command_name=$(command -v "$command_name")" >&2
    exit 1
  fi
done
echo 'system erl/elixir/mix: absent'

echo '== start release =='
"$release/bin/handbean" start >"$work_root/release.log" 2>&1 &
release_pid=$!

ready=false
for _ in $(seq 1 60); do
  if curl --fail --silent --show-error --max-time 2 \
    --dump-header "$work_root/http-headers.txt" \
    --output "$work_root/homepage.html" \
    "http://127.0.0.1:$port/"; then
    ready=true
    break
  fi
  if ! kill -0 "$release_pid" 2>/dev/null; then
    cat "$work_root/release.log" >&2
    exit 1
  fi
  sleep 1
done
[[ $ready == true ]]
head -n 1 "$work_root/http-headers.txt"
test -s "$work_root/homepage.html"
echo "homepage_bytes=$(wc -c < "$work_root/homepage.html")"

echo '== SQLite migration =='
test -s "$DATABASE_PATH"
"$release/bin/handbean" rpc '
integrity = Ecto.Adapters.SQL.query!(Handbean.Repo, "PRAGMA integrity_check", []).rows
migrations = Ecto.Adapters.SQL.query!(Handbean.Repo, "SELECT count(*), max(version) FROM schema_migrations", []).rows
IO.inspect(integrity, label: "sqlite_integrity")
IO.inspect(migrations, label: "sqlite_migrations")
[["ok"]] = integrity
[[count, latest]] = migrations
true = count > 0
true = is_integer(latest)
:ok
'

echo '== release SSL, DNS, and local HTTPS =='
tls_dir="$work_root/tls"
mkdir -p "$tls_dir"
cat >"$tls_dir/openssl.cnf" <<'EOF'
[req]
distinguished_name=req_distinguished_name

[req_distinguished_name]
EOF
"$openssl" req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=HandbeanRuntimeTestCA \
  -config "$tls_dir/openssl.cnf" \
  -keyout "$tls_dir/ca-key.pem" -out "$tls_dir/ca.pem" >/dev/null 2>&1
"$openssl" req -new -newkey rsa:2048 -nodes -subj /CN=localhost \
  -config "$tls_dir/openssl.cnf" \
  -keyout "$tls_dir/server-key.pem" -out "$tls_dir/server.csr" >/dev/null 2>&1
cat >"$tls_dir/server-ext.cnf" <<'EOF'
[server_cert]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
DNS.1=localhost
IP.1=127.0.0.1
EOF
"$openssl" x509 -req -days 1 -sha256 -in "$tls_dir/server.csr" \
  -CA "$tls_dir/ca.pem" -CAkey "$tls_dir/ca-key.pem" -CAcreateserial \
  -extfile "$tls_dir/server-ext.cnf" -extensions server_cert \
  -out "$tls_dir/server.pem" >/dev/null 2>&1
"$openssl" s_server -accept 5443 -key "$tls_dir/server-key.pem" -cert "$tls_dir/server.pem" \
  -www >"$tls_dir/server.log" 2>&1 &
tls_pid=$!

for _ in $(seq 1 10); do
  if curl -kfsS --max-time 2 https://127.0.0.1:5443/ >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -kfsS --max-time 2 https://127.0.0.1:5443/ >/dev/null

"$release/bin/handbean" rpc "
ssl = Application.ensure_all_started(:ssl)
IO.inspect(ssl, label: \"ssl\")
{:ok, _} = ssl
dns = :inet.gethostbyname(~c\"example.com\")
IO.inspect(dns, label: \"dns\")
{:ok, _} = dns
{:ok, _} = Application.ensure_all_started(:inets)
https = :httpc.request(
  :get,
  {~c\"https://localhost:5443/\", []},
  [
    ssl: [
      verify: :verify_peer,
      cacertfile: ~c\"$tls_dir/ca.pem\",
      server_name_indication: ~c\"localhost\",
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ],
    timeout: 10_000
  ],
  []
)
{:ok, {{_version, 200, _reason}, _headers, body}} = https
IO.inspect({:ok, 200, length(body)}, label: \"local_https\")
true = length(body) > 0
:ok
"

kill "$tls_pid"
wait "$tls_pid" 2>/dev/null || true
tls_pid=""

echo '== Ghostty terminal and PTY =='
"$release/bin/handbean" rpc '
true = Code.ensure_loaded?(WhisperCpp.Native)
IO.puts("whisper_nif=loaded")

{:ok, terminal} = Ghostty.Terminal.start_link(cols: 20, rows: 4)
:ok = Ghostty.Terminal.write(terminal, "glibc217-terminal")
{:ok, snapshot} = Ghostty.Terminal.snapshot(terminal, :plain)
IO.inspect(snapshot, label: "terminal_snapshot")
true = String.contains?(snapshot, "glibc217-terminal")
GenServer.stop(terminal)

{:ok, _pty} = Ghostty.PTY.start_link(cmd: "/bin/sh", args: ["-c", "printf glibc217-pty; sleep 0.2"])
pty_data = receive do
  {:data, data} -> data
after
  5_000 -> raise "PTY output timeout"
end
IO.inspect(pty_data, label: "pty_data")
true = String.contains?(pty_data, "glibc217-pty")
receive do
  {:exit, 0} -> :ok
  {:exit, status} -> raise "PTY exited with status #{inspect(status)}"
after
  5_000 -> raise "PTY exit timeout"
end
:ok
'

echo '== normal stop and crash dumps =='
"$release/bin/handbean" stop
wait "$release_pid"
release_pid=""

if find "$work_root" -name erl_crash.dump -print -quit | grep -q .; then
  find "$work_root" -name erl_crash.dump -print
  exit 1
fi
echo 'none'
