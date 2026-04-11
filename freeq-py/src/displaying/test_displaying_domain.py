# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Displaying Domain (IU-dc94bc91)
# Risk Tier: HIGH

# TDD CYCLE:
# 1. pytest test_displaying_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix displaying_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from displaying_domain import _phoenix, Displaying, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "dc94bc9160aafb153fe50715b8bea0fcdbf54a1bcbfc7882e615c283b075b7aa"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Displaying(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
