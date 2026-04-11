# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Raw Domain (IU-efeda2cc)
# Risk Tier: LOW

# TDD CYCLE:
# 1. pytest test_raw_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix raw_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from raw_domain import _phoenix, Raw, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "efeda2ccc8885e8c19b45cd6ce6b0a620d606180036fc7fb5b4661bf61c2fd74"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Raw(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
