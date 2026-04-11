# 🟢 GREEN: State Domain (IU-c1be7307)
# Description: Implements app state management with 5 requirements
# Risk Tier: MEDIUM
# Requirements:
#   1. State versioning and tracking
#   2. State persistence
#   3. State restoration
#   4. State diff/comparison
#   5. State validation

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any
from datetime import datetime
import hashlib
import json

# === TYPES ===

@dataclass
class StateVersion:
    """Version information for state."""
    version: int = 1
    timestamp: datetime = field(default_factory=datetime.now)
    checksum: Optional[str] = None
    parent_version: Optional[int] = None


@dataclass
class State:
    """State domain entity."""
    id: str
    data: Dict[str, Any] = field(default_factory=dict)
    version: StateVersion = field(default_factory=StateVersion)
    persisted: bool = False
    dirty: bool = False
    persist_path: Optional[str] = None
    schema_version: str = "1.0.0"


# === STATE OPERATIONS ===

def compute_checksum(data: Dict[str, Any]) -> str:
    """Compute checksum of state data."""
    json_str = json.dumps(data, sort_keys=True, default=str)
    return hashlib.sha256(json_str.encode()).hexdigest()[:16]


def process(item: State) -> State:
    """Process state and update version/checksum.
    
    Recomputes checksum and marks as dirty if changed.
    """
    new_checksum = compute_checksum(item.data)
    
    is_dirty = item.dirty or new_checksum != item.version.checksum
    
    new_version = StateVersion(
        version=item.version.version,
        timestamp=datetime.now(),
        checksum=new_checksum,
        parent_version=item.version.parent_version
    )
    
    return State(
        id=item.id,
        data=item.data.copy(),
        version=new_version,
        persisted=item.persisted and not is_dirty,
        dirty=is_dirty,
        persist_path=item.persist_path,
        schema_version=item.schema_version
    )


def bump_version(state: State) -> State:
    """Increment state version."""
    new_version = StateVersion(
        version=state.version.version + 1,
        timestamp=datetime.now(),
        checksum=state.version.checksum,
        parent_version=state.version.version
    )
    
    return State(
        id=state.id,
        data=state.data.copy(),
        version=new_version,
        persisted=False,
        dirty=True,
        persist_path=state.persist_path,
        schema_version=state.schema_version
    )


def mark_persisted(state: State) -> State:
    """Mark state as persisted."""
    return State(
        id=state.id,
        data=state.data.copy(),
        version=state.version,
        persisted=True,
        dirty=False,
        persist_path=state.persist_path,
        schema_version=state.schema_version
    )


def set_data(state: State, key: str, value: Any) -> State:
    """Set a value in state data."""
    new_data = state.data.copy()
    new_data[key] = value
    
    return State(
        id=state.id,
        data=new_data,
        version=state.version,
        persisted=False,
        dirty=True,
        persist_path=state.persist_path,
        schema_version=state.schema_version
    )


def get_data(state: State, key: str, default: Any = None) -> Any:
    """Get a value from state data."""
    return state.data.get(key, default)


def diff_states(old: State, new: State) -> List[str]:
    """Compare two states and return list of changed keys."""
    changes = []
    
    all_keys = set(old.data.keys()) | set(new.data.keys())
    
    for key in all_keys:
        old_val = old.data.get(key)
        new_val = new.data.get(key)
        if old_val != new_val:
            changes.append(key)
    
    return changes


def validate_state(state: State, required_keys: List[str]) -> tuple[bool, Optional[str]]:
    """Validate state has required keys.
    
    Returns (is_valid, error_message)
    """
    missing = [k for k in required_keys if k not in state.data]
    if missing:
        return False, f"Missing required keys: {', '.join(missing)}"
    return True, None


def serialize_state(state: State) -> str:
    """Serialize state to JSON string."""
    return json.dumps({
        "id": state.id,
        "data": state.data,
        "version": {
            "version": state.version.version,
            "timestamp": state.version.timestamp.isoformat(),
            "checksum": state.version.checksum,
            "parent_version": state.version.parent_version
        },
        "persisted": state.persisted,
        "dirty": state.dirty,
        "schema_version": state.schema_version
    }, default=str)


def deserialize_state(json_str: str) -> State:
    """Deserialize state from JSON string."""
    data = json.loads(json_str)
    
    version_data = data.get("version", {})
    version = StateVersion(
        version=version_data.get("version", 1),
        timestamp=datetime.fromisoformat(version_data.get("timestamp", datetime.now().isoformat())),
        checksum=version_data.get("checksum"),
        parent_version=version_data.get("parent_version")
    )
    
    return State(
        id=data.get("id", "unknown"),
        data=data.get("data", {}),
        version=version,
        persisted=data.get("persisted", False),
        dirty=data.get("dirty", False),
        persist_path=None,
        schema_version=data.get("schema_version", "1.0.0")
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "c1be73073cd7ec2b952fc4362ceeb5b1ab72cf1d512f19c61f8b58f7dd132840",
    "name": "State Domain",
    "risk_tier": "medium",
}
