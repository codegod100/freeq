# 🟢 GREEN: Requirements Domain (IU-517684c6)
# Description: Implements requirements tracking with 4 requirements
# Risk Tier: LOW
# Requirements:
#   1. Track implementation requirements
#   2. Version requirements
#   3. Check requirement fulfillment
#   4. Generate requirements report

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set
from enum import Enum, auto

# === TYPES ===

class ReqStatus(Enum):
    """Requirement implementation status."""
    PENDING = auto()
    IN_PROGRESS = auto()
    IMPLEMENTED = auto()
    TESTED = auto()
    VERIFIED = auto()


class ReqPriority(Enum):
    """Requirement priority."""
    CRITICAL = auto()
    HIGH = auto()
    MEDIUM = auto()
    LOW = auto()


@dataclass
class Requirement:
    """Single requirement."""
    id: str
    description: str
    status: ReqStatus = ReqStatus.PENDING
    priority: ReqPriority = ReqPriority.MEDIUM
    category: str = "general"
    implemented_by: List[str] = field(default_factory=list)
    tested_by: List[str] = field(default_factory=list)


@dataclass
class Requirements:
    """Requirements domain entity."""
    id: str
    version: str = "1.0.0"
    requirements: Dict[str, Requirement] = field(default_factory=dict)
    categories: Set[str] = field(default_factory=set)
    completed_count: int = 0
    total_count: int = 0


# === REQUIREMENTS OPERATIONS ===

def process(item: Requirements) -> Requirements:
    """Process requirements and update counts."""
    completed = sum(
        1 for r in item.requirements.values()
        if r.status in (ReqStatus.IMPLEMENTED, ReqStatus.TESTED, ReqStatus.VERIFIED)
    )
    
    categories = set(r.category for r in item.requirements.values())
    
    return Requirements(
        id=item.id,
        version=item.version,
        requirements=dict(item.requirements),
        categories=categories,
        completed_count=completed,
        total_count=len(item.requirements)
    )


def add_requirement(
    req: Requirements,
    id: str,
    description: str,
    priority: ReqPriority = ReqPriority.MEDIUM,
    category: str = "general"
) -> Requirements:
    """Add a new requirement."""
    new_reqs = dict(req.requirements)
    new_reqs[id] = Requirement(
        id=id,
        description=description,
        status=ReqStatus.PENDING,
        priority=priority,
        category=category
    )
    
    return Requirements(
        id=req.id,
        version=req.version,
        requirements=new_reqs,
        categories=req.categories | {category},
        completed_count=req.completed_count,
        total_count=len(new_reqs)
    )


def update_status(req: Requirements, id: str, status: ReqStatus) -> Requirements:
    """Update requirement status."""
    if id not in req.requirements:
        return req
    
    new_reqs = dict(req.requirements)
    old = new_reqs[id]
    new_reqs[id] = Requirement(
        id=old.id,
        description=old.description,
        status=status,
        priority=old.priority,
        category=old.category,
        implemented_by=old.implemented_by,
        tested_by=old.tested_by
    )
    
    return Requirements(
        id=req.id,
        version=req.version,
        requirements=new_reqs,
        categories=req.categories,
        completed_count=req.completed_count,
        total_count=req.total_count
    )


def mark_implemented(req: Requirements, id: str, by: str) -> Requirements:
    """Mark requirement as implemented."""
    if id not in req.requirements:
        return req
    
    new_reqs = dict(req.requirements)
    old = new_reqs[id]
    implemented = old.implemented_by.copy()
    if by not in implemented:
        implemented.append(by)
    
    new_reqs[id] = Requirement(
        id=old.id,
        description=old.description,
        status=ReqStatus.IMPLEMENTED,
        priority=old.priority,
        category=old.category,
        implemented_by=implemented,
        tested_by=old.tested_by
    )
    
    return Requirements(
        id=req.id,
        version=req.version,
        requirements=new_reqs,
        categories=req.categories,
        completed_count=req.completed_count + 1,
        total_count=req.total_count
    )


def get_by_status(req: Requirements, status: ReqStatus) -> List[Requirement]:
    """Get all requirements with given status."""
    return [r for r in req.requirements.values() if r.status == status]


def get_by_priority(req: Requirements, priority: ReqPriority) -> List[Requirement]:
    """Get all requirements with given priority."""
    return [r for r in req.requirements.values() if r.priority == priority]


def is_complete(req: Requirements) -> bool:
    """Check if all requirements are complete."""
    return all(
        r.status in (ReqStatus.IMPLEMENTED, ReqStatus.TESTED, ReqStatus.VERIFIED)
        for r in req.requirements.values()
    )


def generate_report(req: Requirements) -> Dict[str, any]:
    """Generate requirements report."""
    by_status = {}
    by_priority = {}
    
    for r in req.requirements.values():
        by_status.setdefault(r.status.name, []).append(r)
        by_priority.setdefault(r.priority.name, []).append(r)
    
    return {
        "version": req.version,
        "total": req.total_count,
        "completed": req.completed_count,
        "percentage": (req.completed_count / req.total_count * 100) if req.total_count else 0,
        "by_status": {k: len(v) for k, v in by_status.items()},
        "by_priority": {k: len(v) for k, v in by_priority.items()},
        "is_complete": is_complete(req)
    }


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "517684c6f05097edc7c4ef9e689240220d2158d6694d618dc1d53589029e1b81",
    "name": "Requirements Domain",
    "risk_tier": "low",
}
