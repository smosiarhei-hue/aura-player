import re
import subprocess
import urllib.request


def get_token():
    res = subprocess.run(["git", "config", "--get", "remote.origin.url"], capture_output=True, text=True, check=True)
    m = re.search(r"oauth2:([^@]+)@", res.stdout)
    return m.group(1) if m else None


token = get_token()
job_id = 104764724076  # let's get job_id from API

url = "https://api.github.com/repos/smosiarhei-hue/aura-player/actions/runs/36981698250/jobs"
req = urllib.request.Request(
    url,
    headers={
        "Authorization": f"token {token}",
        "User-Agent": "Python",
        "Accept": "application/vnd.github.v3+json",
    },
)
with urllib.request.urlopen(req) as resp:
    import json

    data = json.loads(resp.read().decode("utf-8"))
    job_id = data["jobs"][0]["id"]

# GitHub API redirects /logs to S3/Azure with a presigned URL.
# When python urllib follows redirect, it re-sends Authorization header which Azure rejects.
# So we disable auto-redirect to capture Location header.


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = urllib.request.build_opener(NoRedirectHandler)
log_url = f"https://api.github.com/repos/smosiarhei-hue/aura-player/actions/jobs/{job_id}/logs"
req = urllib.request.Request(
    log_url,
    headers={
        "Authorization": f"token {token}",
        "User-Agent": "Python",
    },
)
try:
    opener.open(req)
except urllib.error.HTTPError as e:
    if e.code in (301, 302, 303, 307):
        target_url = e.headers["Location"]
        # Fetch the log from target_url WITHOUT Authorization header
        with urllib.request.urlopen(target_url) as resp:
            log_text = resp.read().decode("utf-8", errors="replace")
            print("Successfully fetched log. Total length:", len(log_text))
            lines = log_text.splitlines()
            # Find lines containing error:
            error_lines = [l for l in lines if "error:" in l.lower()]
            print("\nFound errors:")
            for l in error_lines[-30:]:
                print(l)
    else:
        print("HTTP Error:", e.code, e.reason)
