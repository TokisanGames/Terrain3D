# This scripts dumps all contributors names, handles, and urls for a repository.
# To use modify the settings below.

pat_file = "/c/Users/Cory/github_terrain3d_pat.txt"  # Github Personal Access Token to expand rate limiting
repo_url = "https://api.github.com/repos/TokisanGames/Terrain3D/contributors"

import requests
import sys
import unicodedata
import time
import pathlib

# Set UTF-8 encoding for stdout on all platforms
sys.stdout.reconfigure(encoding='utf-8')

# Function to normalize Unicode characters to ASCII
def normalize_name(name):
    if not name:
        return ""
    try:
        # Normalize Unicode to ASCII, removing diacritics
        normalized = unicodedata.normalize('NFKD', name).encode('ascii', 'ignore').decode('ascii')
        return normalized.strip()
    except Exception:
        return ""

# Function to normalize Git Bash /c/ paths to Windows C:\ paths
def normalize_gitbash_path(path):
    if sys.platform == "win32" and path.startswith("/c/"):
        return "C:\\" + path[3:].replace("/", "\\")
    return path

# Read GitHub PAT from file
pat_file = normalize_gitbash_path(pat_file)
pat_path = pathlib.Path(pat_file)
print(f"Reading PAT file from: {pat_path}")
try:
    with pat_path.open("r", encoding="utf-8") as f:
        github_pat = f.read().strip()
except FileNotFoundError:
    print(f"Error: Could not find PAT file at {pat_path}")
    sys.exit(1)
except Exception as e:
    print(f"Error reading PAT file at {pat_path}: {e}")
    sys.exit(1)

# GitHub API endpoint for contributors
headers = {
    "Accept": "application/vnd.github.v3+json",
    "User-Agent": "Python script",  # Avoid rate-limiting
    "Authorization": f"token {github_pat}"  # Use PAT from file
}
params = {"per_page": 100}  # Max per page

# Fetch all contributors with pagination
contributors = []
page = 1
while True:
    response = requests.get(repo_url, headers=headers, params={**params, "page": page})
    if response.status_code != 200:
        print(f"API error fetching contributors: {response.status_code} - {response.text}")
        break

    try:
        data = response.json()
    except ValueError:
        print(f"Failed to parse JSON response for contributors page {page}")
        break

    # Handle API errors
    if not isinstance(data, list):
        print(f"API error: {data.get('message', 'Unknown error')}")
        break

    if not data:
        break
    contributors.extend(data)
    page += 1

# Process each contributor
for contributor in contributors:
    username = contributor.get("login", "Unknown")
    if username == "Unknown":
        print(f"Skipping contributor with missing login")
        continue

    # Fetch user profile
    profile_url = f"https://api.github.com/users/{username}"
    try:
        profile_response = requests.get(profile_url, headers=headers)
        time.sleep(0.5)  # Delay to avoid rate-limiting
        if profile_response.status_code != 200:
            print(f"Failed to fetch profile for {username}: {profile_response.status_code}")
            name = ""
        else:
            try:
                profile = profile_response.json()
                # Ensure profile is valid and has data
                if not isinstance(profile, dict):
                    print(f"Invalid profile data for {username}")
                    name = ""
                else:
                    # Get published name (leave blank if None or empty)
                    name = profile.get("name", "").strip() if profile.get("name") else ""
                    if name.lower() == "none" or not name:
                        name = ""
                    else:
                        name = normalize_name(name) + " "
            except ValueError:
                print(f"Failed to parse JSON profile for {username}")
                name = ""
    except requests.RequestException as e:
        print(f"Error fetching profile for {username}: {e}")
        name = ""

    # Print formatted output
    try:
        print(f"* {name}[@{username}](https://github.com/{username})")
    except UnicodeEncodeError:
        # Fallback: print without name if encoding fails
        print(f"* [@{username}](https://github.com/{username})")

