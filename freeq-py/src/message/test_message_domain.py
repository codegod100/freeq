# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Message Domain (IU-47e273a9)
# Risk Tier: CRITICAL

# TDD CYCLE:
# 1. pytest test_message_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix message_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from message_domain import _phoenix, Message, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "47e273a9e369409e8160fde1bc0d683f8643ab26d3fdd0f805cf64a7648161c1"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Message(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
