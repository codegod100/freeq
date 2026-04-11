# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Requirements Domain (IU-517684c6)
# Risk Tier: LOW

# TDD CYCLE:
# 1. pytest test_requirements_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix requirements_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from requirements_domain import _phoenix, Requirements, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "517684c6f05097edc7c4ef9e689240220d2158d6694d618dc1d53589029e1b81"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Requirements(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
