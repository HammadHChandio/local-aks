"""Generate an OpenSSH ed25519 keypair when ssh-keygen is unavailable (usage: gen-ssh-key.py <path>)."""
import os
import sys

from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

path = sys.argv[1]
key = Ed25519PrivateKey.generate()
with open(path, "wb") as f:
    f.write(key.private_bytes(s.Encoding.PEM, s.PrivateFormat.OpenSSH, s.NoEncryption()))
os.chmod(path, 0o600)
with open(path + ".pub", "wb") as f:
    f.write(key.public_key().public_bytes(s.Encoding.OpenSSH, s.PublicFormat.OpenSSH) + b" sas-viya-local\n")
