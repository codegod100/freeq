# 🟢 GREEN: Feature Domain (IU-32c20422)
# Description: Implements feature flags and toggles with 4 requirements
# Risk Tier: HIGH
# Requirements:
#   1. Define feature flags for IRCv3 capabilities
#   2. Support runtime feature toggles
#   3. Fallback to simple avatars when advanced rendering unavailable
#   4. Enable/disable features based on server capabilities

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set
from enum import Enum, auto

# === TYPES ===

class FeatureName(Enum):
    """Named feature flags."""
    # IRCv3 capabilities
    SASL = auto()
    AWAY_NOTIFY = auto()
    ACCOUNT_NOTIFY = auto()
    EXTENDED_JOIN = auto()
    CHATHISTORY = auto()
    MSGID = auto()
    REACTIONS = auto()
    EDITS = auto()
    # UI features
    EMOJI_PICKER = auto()
    AVATAR_RENDERING = auto()
    URL_PREVIEW = auto()
    THREAD_PANEL = auto()
    DEBUG_PANEL = auto()


@dataclass
class Feature:
    """Feature domain entity."""
    id: str
    name: FeatureName
    enabled: bool = False
    available: bool = False  # Server supports this feature
    fallback_enabled: bool = False  # Fallback mode active
    config: Dict[str, any] = field(default_factory=dict)
    dependencies: Set[FeatureName] = field(default_factory=set)


@dataclass
class FeatureSet:
    """Collection of features."""
    features: Dict[FeatureName, Feature] = field(default_factory=dict)
    caps_enabled: Set[str] = field(default_factory=set)
    sasl_available: bool = False
    sasl_authenticated: bool = False


# === FEATURE MANAGEMENT ===

def create_feature(name: FeatureName, available: bool = False, enabled: bool = False) -> Feature:
    """Create a new feature with defaults."""
    return Feature(
        id=f"feat_{name.name.lower()}",
        name=name,
        enabled=enabled and available,
        available=available,
        fallback_enabled=False,
        config={},
        dependencies=set()
    )


def process(item: Feature) -> Feature:
    """Process feature state and compute effective enablement.
    
    Ensures feature is not enabled if not available.
    Activates fallback mode if feature unavailable but fallback enabled.
    """
    effective_enabled = item.enabled and item.available
    
    # Determine fallback state
    use_fallback = item.fallback_enabled and not item.available
    
    return Feature(
        id=item.id,
        name=item.name,
        enabled=effective_enabled,
        available=item.available,
        fallback_enabled=use_fallback,
        config=item.config.copy(),
        dependencies=item.dependencies.copy()
    )


def enable_feature(feature: Feature) -> Feature:
    """Enable a feature if available."""
    return Feature(
        id=feature.id,
        name=feature.name,
        enabled=feature.available,  # Only enable if available
        available=feature.available,
        fallback_enabled=not feature.available,
        config=feature.config,
        dependencies=feature.dependencies
    )


def disable_feature(feature: Feature) -> Feature:
    """Disable a feature."""
    return Feature(
        id=feature.id,
        name=feature.name,
        enabled=False,
        available=feature.available,
        fallback_enabled=False,
        config=feature.config,
        dependencies=feature.dependencies
    )


def toggle_feature(feature: Feature) -> Feature:
    """Toggle feature state."""
    if feature.enabled:
        return disable_feature(feature)
    else:
        return enable_feature(feature)


def set_fallback_mode(feature: Feature, use_fallback: bool) -> Feature:
    """Set fallback mode for a feature.
    
    Used to enable fallback implementations (e.g., simple avatars).
    """
    return Feature(
        id=feature.id,
        name=feature.name,
        enabled=feature.enabled,
        available=feature.available,
        fallback_enabled=use_fallback and not feature.available,
        config=feature.config,
        dependencies=feature.dependencies
    )


def update_from_caps(feature_set: FeatureSet, caps: Set[str]) -> FeatureSet:
    """Update feature availability from IRCv3 capability list.
    
    Maps IRCv3 caps to feature availability.
    """
    cap_mapping = {
        "sasl": FeatureName.SASL,
        "away-notify": FeatureName.AWAY_NOTIFY,
        "account-notify": FeatureName.ACCOUNT_NOTIFY,
        "extended-join": FeatureName.EXTENDED_JOIN,
        "draft/chathistory": FeatureName.CHATHISTORY,
        "msgid": FeatureName.MSGID,
        "draft/reactions": FeatureName.REACTIONS,
        "draft/edit": FeatureName.EDITS,
    }
    
    new_features = dict(feature_set.features)
    
    for cap, feat_name in cap_mapping.items():
        available = cap in caps
        if feat_name in new_features:
            # Update existing
            old_feat = new_features[feat_name]
            new_features[feat_name] = Feature(
                id=old_feat.id,
                name=old_feat.name,
                enabled=old_feat.enabled and available,
                available=available,
                fallback_enabled=old_feat.fallback_enabled,
                config=old_feat.config,
                dependencies=old_feat.dependencies
            )
        else:
            # Create new
            new_features[feat_name] = create_feature(feat_name, available=available)
    
    return FeatureSet(
        features=new_features,
        caps_enabled=caps,
        sasl_available="sasl" in caps,
        sasl_authenticated=feature_set.sasl_authenticated
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "32c2042281464980be8e57229e9b8b214d4b1a9feb1741ee375819b71aad7f05",
    "name": "Feature Domain",
    "risk_tier": "high",
}
