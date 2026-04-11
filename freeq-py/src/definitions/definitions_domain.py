# 🟢 GREEN: Definitions Domain (IU-c40ae8a5)
# Description: Implements term definitions with 1 requirement
# Risk Tier: LOW
# Requirement:
#   1. Store and lookup term definitions and abbreviations

from dataclasses import dataclass, field
from typing import Optional, Dict, List

# === TYPES ===

@dataclass
class Definition:
    """A single definition."""
    term: str
    definition: str
    category: Optional[str] = None
    source: Optional[str] = None


@dataclass
class Abbreviation:
    """An abbreviation/expansion."""
    short: str
    full: str
    context: Optional[str] = None


@dataclass
class Definitions:
    """Definitions domain entity."""
    id: str
    terms: Dict[str, Definition] = field(default_factory=dict)
    abbreviations: Dict[str, Abbreviation] = field(default_factory=dict)
    categories: Dict[str, List[str]] = field(default_factory=dict)


# === DEFAULT DEFINITIONS ===

DEFAULT_DEFINITIONS = {
    # IRC Terms
    "nick": Definition("nick", "Nickname - user's display name on IRC", "IRC"),
    "ident": Definition("ident", "Username part of hostmask", "IRC"),
    "hostmask": Definition("hostmask", "User identifier in format nick!ident@host", "IRC"),
    "channel": Definition("channel", "Chat room prefixed with # or &", "IRC"),
    "query": Definition("query", "Private message conversation", "IRC"),
    "op": Definition("op", "Channel operator with moderation privileges", "IRC"),
    "voice": Definition("voice", "Permission to speak in moderated (+m) channels", "IRC"),
    "ban": Definition("ban", "Restriction preventing user from joining channel", "IRC"),
    "kick": Definition("kick", "Forceful removal of user from channel", "IRC"),
    "mode": Definition("mode", "Channel or user setting flag (+n, +t, etc.)", "IRC"),
    "topic": Definition("topic", "Channel description/motd", "IRC"),
    "away": Definition("away", "Status indicating user is not actively watching", "IRC"),
    
    # AT Protocol Terms
    "did": Definition("did", "Decentralized Identifier - unique user identifier", "AT Protocol"),
    "handle": Definition("handle", "Human-readable identifier (e.g., @user.bsky.social)", "AT Protocol"),
    "pds": Definition("pds", "Personal Data Server - stores user's data", "AT Protocol"),
    "plc": Definition("plc", "Placeholder - DID method for Bluesky", "AT Protocol"),
    "at_uri": Definition("at_uri", "AT Protocol URI format for records", "AT Protocol"),
    "repo": Definition("repo", "User's data repository on PDS", "AT Protocol"),
    
    # SASL Terms
    "sasl": Definition("sasl", "Simple Authentication and Security Layer", "Auth"),
    "oauth": Definition("oauth", "Open Authorization protocol for delegated access", "Auth"),
    "dpop": Definition("dpop", "Demonstrating Proof-of-Possession - token security", "Auth"),
}

DEFAULT_ABBREVIATIONS = {
    "irc": Abbreviation("irc", "Internet Relay Chat"),
    "at": Abbreviation("at", "Authenticated Transfer (Protocol)"),
    "did": Abbreviation("did", "Decentralized Identifier"),
    "pds": Abbreviation("pds", "Personal Data Server"),
    "plc": Abbreviation("plc", "Placeholder"),
    "sasl": Abbreviation("sasl", "Simple Authentication and Security Layer"),
    "cap": Abbreviation("cap", "Capability"),
    "msg": Abbreviation("msg", "Message"),
    "chan": Abbreviation("chan", "Channel"),
    "privmsg": Abbreviation("privmsg", "Private Message"),
    "notice": Abbreviation("notice", "Server/Channel Notice"),
    "join": Abbreviation("join", "Join Channel"),
    "part": Abbreviation("part", "Part/Leave Channel"),
    "quit": Abbreviation("quit", "Disconnect from Server"),
    "nick": Abbreviation("nick", "Nickname"),
    "whois": Abbreviation("whois", "User Information Query"),
    "mode": Abbreviation("mode", "User/Channel Mode"),
    "topic": Abbreviation("topic", "Channel Topic"),
    "kick": Abbreviation("kick", "Remove User from Channel"),
    "ban": Abbreviation("ban", "Ban User from Channel"),
    "unban": Abbreviation("unban", "Remove User Ban"),
    "op": Abbreviation("op", "Channel Operator"),
    "deop": Abbreviation("deop", "Remove Channel Operator"),
    "voice": Abbreviation("voice", "Grant Voice Privilege"),
    "devoice": Abbreviation("devoice", "Remove Voice Privilege"),
}


# === DEFINITIONS OPERATIONS ===

def process(item: Definitions) -> Definitions:
    """Process definitions and update categories index."""
    categories: Dict[str, List[str]] = {}
    
    for term, defn in item.terms.items():
        cat = defn.category or "General"
        if cat not in categories:
            categories[cat] = []
        categories[cat].append(term)
    
    return Definitions(
        id=item.id,
        terms=item.terms.copy(),
        abbreviations=item.abbreviations.copy(),
        categories=categories
    )


def create_default_definitions(id: str = "default") -> Definitions:
    """Create definitions with default IRC/AT terms."""
    return Definitions(
        id=id,
        terms=dict(DEFAULT_DEFINITIONS),
        abbreviations=dict(DEFAULT_ABBREVIATIONS),
        categories={}
    )


def add_term(definitions: Definitions, term: str, definition: str, category: Optional[str] = None) -> Definitions:
    """Add a new term definition."""
    new_terms = definitions.terms.copy()
    new_terms[term.lower()] = Definition(term, definition, category)
    
    return Definitions(
        id=definitions.id,
        terms=new_terms,
        abbreviations=definitions.abbreviations.copy(),
        categories=definitions.categories.copy()
    )


def lookup_term(definitions: Definitions, term: str) -> Optional[Definition]:
    """Look up a term definition."""
    return definitions.terms.get(term.lower())


def add_abbreviation(definitions: Definitions, short: str, full: str, context: Optional[str] = None) -> Definitions:
    """Add a new abbreviation."""
    new_abbrs = definitions.abbreviations.copy()
    new_abbrs[short.lower()] = Abbreviation(short, full, context)
    
    return Definitions(
        id=definitions.id,
        terms=definitions.terms.copy(),
        abbreviations=new_abbrs,
        categories=definitions.categories.copy()
    )


def expand_abbreviation(definitions: Definitions, short: str) -> Optional[str]:
    """Expand an abbreviation to full form."""
    abbr = definitions.abbreviations.get(short.lower())
    return abbr.full if abbr else None


def search_terms(definitions: Definitions, query: str) -> List[Definition]:
    """Search for terms matching query."""
    query = query.lower()
    results = []
    
    for term, defn in definitions.terms.items():
        if query in term.lower() or query in defn.definition.lower():
            results.append(defn)
    
    return results


def get_terms_by_category(definitions: Definitions, category: str) -> List[Definition]:
    """Get all terms in a category."""
    return [
        defn for defn in definitions.terms.values()
        if defn.category == category
    ]


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "c40ae8a571196ecf7450fd67b205abbc07d9bd4b5481c4248a8bbaaff1d7aefe",
    "name": "Definitions Domain",
    "risk_tier": "low",
}
