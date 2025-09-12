import requests
import sys
import unicodedata
import time

# Ensure UTF-8 encoding for output
if sys.platform == "win32":
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

# GitHub API endpoint for contributors
url = "https://api.github.com/repos/TokisanGames/Terrain3D/contributors"
headers = {
    "Accept": "application/vnd.github.v3+json",
    "User-Agent": "Python script",  # Avoid rate-limiting
    "Authorization": "github_pat_123456"  # Your personal access token
}
params = {"per_page": 100}  # Max per page

# Fetch all contributors with pagination
contributors = []
page = 1
while True:
    response = requests.get(url, headers=headers, params={**params, "page": page})
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
        time.sleep(0.5)  # Added delay to avoid rate-limiting
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

