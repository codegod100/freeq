# 🟢 GREEN: CLI Domain (IU-285ffb21)
# Description: Implements CLI argument parsing with 4 requirements
# Risk Tier: CRITICAL
# Requirements:
#   1. Parse command-line arguments for broker-url, session-path, auth-handle
#   2. Support --broker-url for custom broker endpoint
#   3. Support --session-path for session file location
#   4. Support --auth-handle for pre-filled AT handle

from dataclasses import dataclass, field
from typing import Optional, List
from argparse import ArgumentParser, Namespace

# === TYPES ===

@dataclass
class CliOptions:
    """Parsed CLI options container."""
    broker_url: str = "https://auth.freeq.at"
    session_path: str = "~/.config/freeq/session.json"
    auth_handle: Optional[str] = None
    debug: bool = False
    verbose: bool = False

@dataclass
class Cli:
    """CLI Domain entity."""
    id: str
    options: CliOptions = field(default_factory=CliOptions)
    raw_args: List[str] = field(default_factory=list)
    parsed: bool = False
    error_message: Optional[str] = None


# === CLI PARSER ===

def create_parser() -> ArgumentParser:
    """Create the argument parser with all FreeQ CLI options."""
    parser = ArgumentParser(
        prog="freeq-textual",
        description="FreeQ IRC Textual TUI - AT Protocol authenticated IRC client"
    )
    
    parser.add_argument(
        "--broker-url",
        type=str,
        default="https://auth.freeq.at",
        help="Broker URL for authentication (default: https://auth.freeq.at)"
    )
    
    parser.add_argument(
        "--session-path",
        type=str,
        default="~/.config/freeq/session.json",
        help="Path to session file (default: ~/.config/freeq/session.json)"
    )
    
    parser.add_argument(
        "--auth-handle",
        type=str,
        default=None,
        help="Pre-fill AT handle for authentication"
    )
    
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug mode"
    )
    
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose output"
    )
    
    return parser


def parse_args(args: Optional[List[str]] = None) -> CliOptions:
    """Parse command-line arguments into CliOptions."""
    parser = create_parser()
    namespace = parser.parse_args(args)
    
    return CliOptions(
        broker_url=namespace.broker_url,
        session_path=namespace.session_path,
        auth_handle=namespace.auth_handle,
        debug=namespace.debug,
        verbose=namespace.verbose
    )


# === GREEN IMPLEMENTATIONS ===

def process(item: Cli) -> Cli:
    """Process CLI arguments and populate options.
    
    Transforms the input Cli by parsing raw_args into structured options.
    Creates a new Cli instance with parsed configuration.
    """
    # Parse the arguments
    options = parse_args(item.raw_args)
    
    # Return new instance with parsed options
    return Cli(
        id=item.id,
        options=options,
        raw_args=item.raw_args,
        parsed=True,
        error_message=None
    )


def validate_options(options: CliOptions) -> tuple[bool, Optional[str]]:
    """Validate parsed CLI options.
    
    Returns:
        Tuple of (is_valid, error_message)
    """
    # Validate broker URL has proper scheme
    if not options.broker_url.startswith(("http://", "https://")):
        return False, f"Invalid broker URL: {options.broker_url}"
    
    # Validate session path is not empty
    if not options.session_path:
        return False, "Session path cannot be empty"
    
    return True, None


def expand_session_path(options: CliOptions) -> str:
    """Expand user home directory in session path."""
    import os
    return os.path.expanduser(options.session_path)


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "285ffb214c94e21635e7e12e61f5f2c6263b0bf89858a8c6c7341d03238f51b7",
    "name": "CLI Domain",
    "risk_tier": "critical",
}
