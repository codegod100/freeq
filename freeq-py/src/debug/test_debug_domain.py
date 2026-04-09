# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Debug Domain (IU-b30d2898)
# Risk Tier: LOW

# TDD CYCLE:
# 1. pytest test_debug_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix debug_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from debug_domain import _phoenix, Debug, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "b30d289829c7bcbf15106b195f0ad1149b83e3b19fc07cbd860e1cb0cb5e3769"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Debug(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
