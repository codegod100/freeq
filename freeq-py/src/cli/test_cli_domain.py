# 🟢 GREEN: Tests for CLI Domain (IU-285ffb21)
# Risk Tier: CRITICAL

import pytest
from cli_domain import _phoenix, Cli, CliOptions, process, parse_args, validate_options, expand_session_path

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "285ffb214c94e21635e7e12e61f5f2c6263b0bf89858a8c6c7341d03238f51b7"


# 🟢 GREEN: CLI argument parsing tests
def test_parse_args_default_values():
    """Test that default values are set correctly."""
    options = parse_args([])
    assert options.broker_url == "https://auth.freeq.at"
    assert options.session_path == "~/.config/freeq/session.json"
    assert options.auth_handle is None
    assert options.debug is False
    assert options.verbose is False


def test_parse_args_custom_broker_url():
    """Test --broker-url option."""
    options = parse_args(["--broker-url", "https://custom.broker.com"])
    assert options.broker_url == "https://custom.broker.com"


def test_parse_args_custom_session_path():
    """Test --session-path option."""
    options = parse_args(["--session-path", "/custom/path/session.json"])
    assert options.session_path == "/custom/path/session.json"


def test_parse_args_auth_handle():
    """Test --auth-handle option."""
    options = parse_args(["--auth-handle", "@user.bsky.social"])
    assert options.auth_handle == "@user.bsky.social"


def test_parse_args_debug_and_verbose():
    """Test --debug and --verbose flags."""
    options = parse_args(["--debug", "-v"])
    assert options.debug is True
    assert options.verbose is True


# 🟢 GREEN: Process function tests
def test_process_transforms_input():
    """Test that process creates a new Cli instance with parsed options."""
    input_item = Cli(id="123", raw_args=["--broker-url", "https://test.com"])
    result = process(input_item)
    
    # Should be new object
    assert result is not input_item
    # Should be marked as parsed
    assert result.parsed is True
    # Should have parsed options
    assert result.options.broker_url == "https://test.com"


def test_process_preserves_id():
    """Test that process preserves the original ID."""
    input_item = Cli(id="test-id-123", raw_args=[])
    result = process(input_item)
    assert result.id == "test-id-123"


# 🟢 GREEN: Validation tests
def test_validate_options_valid():
    """Test validation with valid options."""
    options = CliOptions(broker_url="https://valid.url", session_path="/valid/path")
    is_valid, error = validate_options(options)
    assert is_valid is True
    assert error is None


def test_validate_options_invalid_broker_url():
    """Test validation with invalid broker URL."""
    options = CliOptions(broker_url="ftp://invalid.com", session_path="/valid/path")
    is_valid, error = validate_options(options)
    assert is_valid is False
    assert "Invalid broker URL" in error


def test_validate_options_empty_session_path():
    """Test validation with empty session path."""
    options = CliOptions(broker_url="https://valid.url", session_path="")
    is_valid, error = validate_options(options)
    assert is_valid is False
    assert "Session path cannot be empty" in error


# 🟢 GREEN: Session path expansion test
def test_expand_session_path():
    """Test session path expansion."""
    options = CliOptions(session_path="~/.config/freeq/session.json")
    expanded = expand_session_path(options)
    assert expanded.startswith("/")
    assert "~" not in expanded
