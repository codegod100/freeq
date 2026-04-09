# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Reactions Domain (IU-f9f9717b)
# Risk Tier: LOW

# TDD CYCLE:
# 1. pytest test_reactions_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix reactions_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from reactions_domain import _phoenix, Reactions, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "f9f9717b1642bcca7f6066156bd89c8c40c3666639356d5522387bbeff9213cc"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Reactions(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
