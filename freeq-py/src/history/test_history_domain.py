# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# History Domain (IU-5724b98e)
# Risk Tier: LOW

# TDD CYCLE:
# 1. pytest test_history_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix history_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from history_domain import _phoenix, History, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "5724b98e9464bf6b84ebdf774812faafe1e5f7eda8fd087aac5653e855de0027"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = History(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
