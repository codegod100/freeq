# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Input Domain (IU-7d70783c)
# Risk Tier: LOW

# TDD CYCLE:
# 1. pytest test_input_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix input_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from input_domain import _phoenix, Input, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "7d70783cca541aff14d61fc9b06aaecd55de5581ec26af3f1b9e1d1a85e34094"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Input(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
