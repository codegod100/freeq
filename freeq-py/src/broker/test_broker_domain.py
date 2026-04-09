# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# Broker Domain (IU-8d8ce46d)
# Risk Tier: CRITICAL

# TDD CYCLE:
# 1. pytest test_broker_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix broker_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from broker_domain import _phoenix, Broker, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "8d8ce46d6dca57e464c29be8d30b1fca0d51e04962f96b3972746591adb671f2"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Broker(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
