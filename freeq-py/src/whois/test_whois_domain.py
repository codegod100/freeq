# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# WHOIS Domain (IU-f980a837)
# Risk Tier: LOW

# TDD CYCLE:
# 1. pytest test_whois_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix whois_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from whois_domain import _phoenix, Whois, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "f980a83755dc73d8e251276fa24fafe586d2a22cf8ecafc85669da00b401ddbe"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Whois(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
