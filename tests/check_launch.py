"""Catch a valid executable that never enters the AppKit application lifecycle."""
import subprocess
import sys

process = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    stdout, stderr = process.communicate(timeout=5)
except subprocess.TimeoutExpired:
    process.terminate()
    try:
        process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=5)
    print('Application remained running through its startup window.')
else:
    raise SystemExit(f'Application exited during startup ({process.returncode}): {stderr.decode(errors="replace")[:1000]}')
