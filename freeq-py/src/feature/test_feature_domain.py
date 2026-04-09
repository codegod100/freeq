# 🟢 GREEN: Tests for Feature Domain (IU-32c20422)
# Risk Tier: HIGH

import pytest
from feature_domain import (
    _phoenix, Feature, FeatureName, FeatureSet, process,
    create_feature, enable_feature, disable_feature, toggle_feature,
    set_fallback_mode, update_from_caps
)

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "32c2042281464980be8e57229e9b8b214d4b1a9feb1741ee375819b71aad7f05"


# 🟢 GREEN: Feature creation tests
def test_create_feature():
    """Test creating a feature with defaults."""
    feat = create_feature(FeatureName.SASL, available=True, enabled=True)
    assert feat.name == FeatureName.SASL
    assert feat.available is True
    assert feat.enabled is True
    assert feat.fallback_enabled is False


def test_create_feature_unavailable():
    """Test creating unavailable feature."""
    feat = create_feature(FeatureName.AVATAR_RENDERING, available=False, enabled=True)
    assert feat.available is False
    assert feat.enabled is False  # Cannot enable if unavailable


# 🟢 GREEN: Process function tests
def test_process_enables_if_available():
    """Test that process enables feature if available."""
    feat = Feature(id="f1", name=FeatureName.SASL, enabled=True, available=True)
    result = process(feat)
    assert result.enabled is True


def test_process_disables_if_unavailable():
    """Test that process disables feature if not available."""
    feat = Feature(id="f1", name=FeatureName.SASL, enabled=True, available=False)
    result = process(feat)
    assert result.enabled is False


def test_process_preserves_fallback():
    """Test that process preserves fallback mode."""
    feat = Feature(
        id="f1", name=FeatureName.AVATAR_RENDERING,
        enabled=False, available=False, fallback_enabled=True
    )
    result = process(feat)
    assert result.fallback_enabled is True


def test_process_creates_new_object():
    """Test that process creates a new object."""
    feat = Feature(id="f1", name=FeatureName.SASL, enabled=True, available=True)
    result = process(feat)
    assert result is not feat


# 🟢 GREEN: Enable/disable tests
def test_enable_feature():
    """Test enabling a feature."""
    feat = Feature(id="f1", name=FeatureName.SASL, enabled=False, available=True)
    result = enable_feature(feat)
    assert result.enabled is True


def test_enable_unavailable_feature():
    """Test enabling unavailable feature triggers fallback."""
    feat = Feature(id="f1", name=FeatureName.SASL, enabled=False, available=False)
    result = enable_feature(feat)
    assert result.enabled is False
    assert result.fallback_enabled is True


def test_disable_feature():
    """Test disabling a feature."""
    feat = Feature(id="f1", name=FeatureName.SASL, enabled=True, available=True)
    result = disable_feature(feat)
    assert result.enabled is False
    assert result.fallback_enabled is False


def test_toggle_feature():
    """Test toggling feature state."""
    feat = Feature(id="f1", name=FeatureName.SASL, enabled=False, available=True)
    result = toggle_feature(feat)
    assert result.enabled is True
    
    result2 = toggle_feature(result)
    assert result2.enabled is False


# 🟢 GREEN: Fallback mode tests
def test_set_fallback_mode():
    """Test setting fallback mode."""
    feat = Feature(id="f1", name=FeatureName.AVATAR_RENDERING, available=False)
    result = set_fallback_mode(feat, True)
    assert result.fallback_enabled is True


def test_set_fallback_mode_ignored_if_available():
    """Test fallback ignored if feature available."""
    feat = Feature(id="f1", name=FeatureName.SASL, available=True)
    result = set_fallback_mode(feat, True)
    assert result.fallback_enabled is False  # No fallback needed


# 🟢 GREEN: CAP updates tests
def test_update_from_caps():
    """Test updating features from IRCv3 CAP list."""
    feat_set = FeatureSet()
    caps = {"sasl", "away-notify", "msgid"}
    
    result = update_from_caps(feat_set, caps)
    
    assert FeatureName.SASL in result.features
    assert result.features[FeatureName.SASL].available is True
    assert result.features[FeatureName.AWAY_NOTIFY].available is True
    assert "sasl" in result.caps_enabled
    assert result.sasl_available is True


def test_update_from_caps_preserves_state():
    """Test that CAP updates preserve existing feature state."""
    feat = Feature(id="f_sasl", name=FeatureName.SASL, enabled=True)
    feat_set = FeatureSet(features={FeatureName.SASL: feat})
    
    result = update_from_caps(feat_set, {"sasl"})
    
    # Should keep enabled state
    assert result.features[FeatureName.SASL].enabled is True


def test_process_transforms_input():
    """Ensure process creates new object (backwards compatibility)."""
    input_item = Feature(id="123", name=FeatureName.SASL, enabled=True, available=True)
    result = process(input_item)
    assert result is not input_item
