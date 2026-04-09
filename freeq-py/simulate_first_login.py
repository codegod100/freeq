#!/usr/bin/env python3
"""
Simulate first-time login to test auto-login feature.

This script creates mock credentials so you can test the auto-login
flow without actually authenticating via OAuth.

Usage:
    python simulate_first_login.py
    
Then run your app and it will auto-login!
"""

import json
import sys
from pathlib import Path
from datetime import datetime

# Add project to path
sys.path.insert(0, "/home/nandi/code/freeq/freeq-py")

def simulate_first_login():
    """Create mock credentials file to test auto-login."""
    
    print("═" * 60)
    print("  SIMULATE FIRST LOGIN - Create Test Credentials")
    print("═" * 60)
    print()
    
    # Create test credentials
    test_creds = {
        "handle": "testuser.bsky.social",
        "did": "did:plc:test123abc",
        "nick": "TestUser",
        "web_token": "test_token_for_auto_login_testing",
        "timestamp": datetime.now().isoformat(),
    }
    
    # Ensure directory exists
    auth_dir = Path.home() / ".config" / "freeq"
    auth_dir.mkdir(parents=True, exist_ok=True)
    
    # Write credentials file
    auth_path = auth_dir / "auth.json"
    with open(auth_path, 'w') as f:
        json.dump(test_creds, f, indent=2)
    
    print(f"✅ Created: {auth_path}")
    print()
    print("Credentials saved:")
    print(f"  Handle: {test_creds['handle']}")
    print(f"  Nick:   {test_creds['nick']}")
    print(f"  DID:    {test_creds['did'][:30]}...")
    print()
    print("═" * 60)
    print("  ✅ AUTO-LOGIN NOW ENABLED")
    print("═" * 60)
    print()
    print("Next steps:")
    print("  1. Run your app: python -m freeq_textual.app")
    print("  2. Watch for these log messages:")
    print("     [AUTH-MOUNT] Starting on_mount, checking for saved credentials...")
    print("     [AUTH-MOUNT] load_saved_credentials returned: True")
    print("     [AUTH-MOUNT] Saved credentials found, attempting auto-login")
    print("     [AUTH-MOUNT] Auto-login complete, main UI should be visible")
    print()
    print("  3. AuthScreen should be SKIPPED!")
    print()
    print("To remove test credentials:")
    print(f"  rm {auth_path}")
    print()
    print("═" * 60)

if __name__ == "__main__":
    simulate_first_login()
