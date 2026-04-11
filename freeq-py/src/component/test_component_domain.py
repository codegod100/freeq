# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Component Domain (IU-652110a4)
# Risk Tier: LOW

# TDD CYCLE:
# 1. pytest test_component_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix component_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from component_domain import _phoenix, Component, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "652110a4a2931fc911ea1e0fe1bc17748aaac8728418684817c8274f9924b3aa"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Component(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
