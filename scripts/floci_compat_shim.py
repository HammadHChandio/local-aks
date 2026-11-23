"""Minimal ARM compatibility shim in front of Floci AZ (local mode only).

It forwards every request unchanged to Floci and applies ONLY the rewrites listed in RULES, each of
which corrects a verified Floci defect (not a missing capability). Every rewrite is logged with the
request path, so tests can report it. Disable with FLOCI_COMPAT_SHIM=0 (point metadata_host at :4577).

Rule 1 - AKS user credential name
  Floci 0.17.0 AksHandler answers listClusterUserCredential with kubeconfigs[].name = "clusterAdmin".
  azurerm 4.64.0 (kubernetes_cluster_resource.go: flattenKubernetesClusterCredentials(..., "clusterUser"))
  selects the user kubeconfig by name, so kube_config/kube_config_raw stay empty and the upstream
  viya4-iac-azure azure_aks module fails every refresh ("Invalid index" on kube_config[0]).
  The kubeconfig content (real k3s CA, cert and key) is passed through untouched.
"""
import http.client
import http.server
import json
import os
import re
import socketserver
import ssl
import sys

UPSTREAM = os.environ.get("FLOCI_UPSTREAM", "floci-az:4577")
LISTEN = int(os.environ.get("SHIM_PORT", "4578"))
TLS_DIR = os.environ.get("TLS_DIR", "/tls")
HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-connection"}
USER_CRED = re.compile(r"/providers/Microsoft\.ContainerService/managedClusters/[^/]+/listClusterUserCredential", re.I)


def rule_user_credential_name(method, path, status, body):
    if method != "POST" or status != 200 or not USER_CRED.search(path):
        return body, None
    doc = json.loads(body)
    changed = False
    for kc in doc.get("kubeconfigs", []):
        if kc.get("name") == "clusterAdmin":
            kc["name"] = "clusterUser"
            changed = True
    return (json.dumps(doc).encode(), "aks-user-credential-name") if changed else (body, None)


RULES = [rule_user_credential_name]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        headers["X-Forwarded-Proto"] = "https"  # Floci builds /metadata/endpoints from this + Host
        conn = http.client.HTTPConnection(UPSTREAM, timeout=600)
        conn.request(self.command, self.path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        for rule in RULES:
            data, applied = rule(self.command, self.path, resp.status, data)
            if applied:
                print(f"REWRITE {applied} {self.command} {self.path.split('?')[0]}", flush=True)
        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() not in HOP and k.lower() != "content-length":
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        conn.close()

    do_GET = do_PUT = do_POST = do_PATCH = do_DELETE = do_HEAD = _forward

    def log_message(self, *_):  # quiet; only rewrites are logged
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(f"{TLS_DIR}/floci-az-selfsigned.crt", f"{TLS_DIR}/floci-az-selfsigned.key")
    srv = Server(("0.0.0.0", LISTEN), Handler)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"floci-compat-shim :{LISTEN} -> {UPSTREAM} rules={[r.__name__ for r in RULES]}", file=sys.stderr, flush=True)
    srv.serve_forever()
