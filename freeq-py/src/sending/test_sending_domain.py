# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Sending Domain (IU-4bf9919c)
# Risk Tier: LOW

# TDD CYCLE:
# 1. pytest test_sending_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix sending_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from sending_domain import _phoenix, Sending, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "4bf9919c784822ee9c65837f5e5a98ea270fc439997d55078391bc301d176703"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Sending(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
