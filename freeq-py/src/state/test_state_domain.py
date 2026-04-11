# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# State Domain (IU-c1be7307)
# Risk Tier: MEDIUM

# TDD CYCLE:
# 1. pytest test_state_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix state_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from state_domain import _phoenix, State, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "c1be73073cd7ec2b952fc4362ceeb5b1ab72cf1d512f19c61f8b58f7dd132840"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = State(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
