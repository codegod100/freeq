import { useEffect, useRef, useState, useMemo } from 'react';

// Emoji data: [emoji, ...keywords]
export const EMOJI_DATA: [string, ...string[]][] = [
  // Smileys
  ['😀','grin','happy','smile'],['😃','smile','happy'],['😄','laugh','happy'],['😁','grin','teeth'],
  ['😂','laugh','cry','lol','tears'],['🤣','rofl','lol','laugh'],['🥹','grateful','touched','cry'],
  ['😊','blush','happy','smile'],['😇','angel','innocent','halo'],['🥰','love','hearts','adore'],
  ['😍','heart eyes','love'],['🤩','star','excited','starstruck'],['😘','kiss','love'],
  ['😜','wink','tongue','playful'],['🤪','crazy','zany','wild'],['😎','cool','sunglasses'],
  ['🤓','nerd','glasses'],['🥳','party','celebrate','birthday'],['😤','angry','huff','mad'],
  ['😡','angry','rage','mad'],['🥺','pleading','puppy','please'],['😭','cry','sob','sad'],
  ['😱','scream','shocked','horror'],['😰','anxious','nervous','sweat'],['🤔','think','hmm'],
  ['🤫','shush','secret','quiet'],['🤭','oops','giggle'],['🫣','peek','shy'],
  ['😴','sleep','zzz','tired'],['🤮','vomit','sick','gross'],['🤯','mind blown','explode'],
  ['💀','skull','dead','rip'],['👻','ghost','boo','spooky'],['🤖','robot','bot'],
  ['👽','alien','ufo'],['💩','poop','shit'],['🤡','clown'],['😈','devil','evil'],
  ['🫠','melt','dissolve'],['🙃','upside down','sarcasm'],['🫤','meh','skeptical'],
  ['😬','grimace','awkward','yikes'],['🙄','eye roll','whatever'],['😏','smirk'],
  // Gestures
  ['👍','thumbs up','yes','good','ok','+1'],['👎','thumbs down','no','bad','-1'],
  ['👋','wave','hello','hi','bye'],['🤝','handshake','deal','agree'],
  ['🙌','raise','hooray','celebrate'],['👏','clap','bravo','applause'],
  ['💪','strong','flex','muscle','bicep'],['🫡','salute'],['🫶','heart hands','love'],
  ['✌️','peace','victory'],['🤞','crossed fingers','luck','hope'],['🤙','call','shaka','hang loose'],
  ['🖐️','hand','high five'],['☝️','point up'],['🫵','point','you'],
  ['👆','up'],['👇','down'],['👈','left'],['👉','right'],['🤌','pinch','italian','chef kiss'],
  ['🤏','tiny','small','pinch'],['🖕','middle finger','fuck'],['✊','fist','power'],
  ['👊','punch','fist bump'],['🤘','rock','metal','horns'],
  // Hearts
  ['❤️','heart','love','red'],['🧡','orange heart'],['💛','yellow heart'],['💚','green heart'],
  ['💙','blue heart'],['💜','purple heart'],['🖤','black heart'],['🤍','white heart'],
  ['💔','broken heart','sad'],['❤️‍🔥','fire heart','passion'],
  ['💕','two hearts'],['💞','revolving hearts'],['💗','growing heart'],['💖','sparkling heart'],
  // Objects
  ['🔥','fire','hot','lit'],['⭐','star'],['✨','sparkle','magic','clean'],
  ['💫','dizzy','star'],['🎉','party','celebrate','tada'],['🎊','confetti','celebrate'],
  ['🏆','trophy','winner','champion'],['🎯','target','bullseye','goal'],
  ['💡','idea','lightbulb','tip'],['🔒','lock','secure','private'],['🔑','key'],
  ['💎','gem','diamond'],['⚡','lightning','zap','fast','electric'],
  ['💬','speech','chat','message'],['👀','eyes','look','see','watching'],
  ['🧠','brain','smart','think'],['🫧','bubbles'],['🪄','magic','wand'],
  ['📎','paperclip','clippy'],['🔗','link','url'],['📌','pin'],['📝','memo','note','write'],
  ['💻','laptop','computer','code'],['⌨️','keyboard','type'],['🖥️','desktop','monitor'],
  ['📱','phone','mobile'],['🎮','game','controller','play'],['🎵','music','note'],
  ['🎶','music','notes'],['🎸','guitar','rock'],['🎤','mic','karaoke','sing'],
  ['🕺','man dancing','dance','dancer'],['💃','woman dancing','dance','dancer'],['🎷','saxophone','sax','jazz'],
  ['📷','camera','photo'],['🎬','movie','film','action'],['📚','books','read','study'],
  ['☕','coffee','cafe'],['🍺','beer','drink','cheers'],['🍕','pizza','food'],
  ['🌮','taco','food','mexican'],['🍜','noodle','ramen','soup'],['🍣','sushi'],
  ['🚀','rocket','launch','ship','deploy'],['✈️','plane','travel','fly'],
  ['🏠','house','home'],['🌍','earth','world','globe'],['🌙','moon','night'],
  ['☀️','sun','sunny','bright'],['🌈','rainbow'],['🐱','cat','meow'],['🐶','dog','woof'],
  // Symbols
  ['✅','check','yes','done','correct'],['❌','x','no','wrong','cross'],
  ['⚠️','warning','caution','alert'],['❓','question'],['❗','exclamation','important'],
  ['💯','hundred','perfect','score'],['♻️','recycle','green'],
  ['🔴','red circle'],['🟢','green circle'],['🔵','blue circle'],
  ['🟥','red square'],['🟧','orange square'],['🟨','yellow square'],
  ['🟩','green square'],['🟦','blue square'],['🟪','purple square'],
  ['⬛','black square'],['⬜','white square'],
  ['➕','plus','add'],['➖','minus','subtract'],['✖️','multiply'],['➗','divide'],
  ['💤','zzz','sleep'],['🚫','no','prohibited','ban'],['⛔','stop','no entry'],
  // Flags
  ['🏳️','white flag'],['🏴','black flag'],['🏁','checkered flag','finish','race'],
  ['🚩','red flag','warning'],['🏳️‍🌈','rainbow flag','pride','lgbtq'],['🏳️‍⚧️','trans flag','transgender'],
];

// Build search index
const EMOJI_INDEX = EMOJI_DATA.map(([emoji, ...keywords]) => ({
  emoji,
  keywords: keywords.join(' ').toLowerCase(),
}));

const CATEGORIES = [
  { name: 'Smileys', range: [0, 38] as [number, number] },
  { name: 'Gestures', range: [38, 60] as [number, number] },
  { name: 'Hearts', range: [60, 74] as [number, number] },
  { name: 'Objects', range: [74, 119] as [number, number] },
  { name: 'Symbols', range: [119, 139] as [number, number] },
  { name: 'Flags', range: [139, 145] as [number, number] },
];

const FREQUENT_KEY = 'freeq-emoji-frequent';

// freeq's music/dance brand up front, alongside the usual reactions — shown as
// the default "frequent" row until the user builds their own.
const BRAND_DEFAULT_FREQUENT = ['🕺','💃','🎶','🎷','👍','❤️','😂','🎉','👀','🔥'];

function getFrequent(): string[] {
  try {
    const stored = JSON.parse(localStorage.getItem(FREQUENT_KEY) || '[]');
    return (Array.isArray(stored) && stored.length ? stored : BRAND_DEFAULT_FREQUENT).slice(0, 24);
  } catch { return BRAND_DEFAULT_FREQUENT; }
}

function recordUsage(emoji: string) {
  try {
    const freq = getFrequent().filter((e: string) => e !== emoji);
    freq.unshift(emoji);
    localStorage.setItem(FREQUENT_KEY, JSON.stringify(freq.slice(0, 24)));
  } catch { /* ignore */ }
}

interface EmojiPickerProps {
  onSelect: (emoji: string) => void;
  onClose: () => void;
  position?: { x: number; y: number };
}

export function EmojiPicker({ onSelect, onClose, position }: EmojiPickerProps) {
  const [search, setSearch] = useState('');
  const ref = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose();
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [onClose]);

  const frequent = useMemo(() => getFrequent(), []);

  const searchResults = useMemo(() => {
    if (!search.trim()) return null;
    const q = search.toLowerCase().trim();
    return EMOJI_INDEX
      .filter((e) => e.keywords.includes(q))
      .map((e) => e.emoji);
  }, [search]);

  const handleSelect = (emoji: string) => {
    recordUsage(emoji);
    onSelect(emoji);
    onClose();
  };

  const style: React.CSSProperties = position
    ? { position: 'fixed', left: position.x, bottom: window.innerHeight - position.y, zIndex: 100 }
    : {};

  return (
    <div
      ref={ref}
      style={style}
      className="bg-bg-secondary border border-border rounded-xl shadow-2xl w-80 animate-fadeIn overflow-hidden"
    >
      <div className="p-2 border-b border-border">
        <input
          ref={inputRef}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search emoji..."
          className="w-full bg-bg-tertiary rounded px-2 py-1.5 text-xs text-fg outline-none placeholder:text-fg-dim"
        />
      </div>
      <div className="max-h-[280px] overflow-y-auto p-1">
        {searchResults !== null ? (
          <div>
            <div className="text-[10px] uppercase tracking-wider text-fg-dim px-1.5 py-1 font-semibold">
              Results {searchResults.length > 0 && `(${searchResults.length})`}
            </div>
            {searchResults.length === 0 ? (
              <div className="text-xs text-fg-dim px-2 py-4 text-center">No emoji found</div>
            ) : (
              <div className="flex flex-wrap">
                {searchResults.map((emoji) => (
                  <button key={emoji} onClick={() => handleSelect(emoji)}
                    className="w-8 h-8 flex items-center justify-center text-lg hover:bg-bg-tertiary rounded transition-colors">
                    {emoji}
                  </button>
                ))}
              </div>
            )}
          </div>
        ) : (
          <>
            {frequent.length > 0 && (
              <div>
                <div className="text-[10px] uppercase tracking-wider text-fg-dim px-1.5 py-1 font-semibold">
                  Frequently Used
                </div>
                <div className="flex flex-wrap">
                  {frequent.map((emoji, i) => (
                    <button key={`freq-${i}`} onClick={() => handleSelect(emoji)}
                      className="w-8 h-8 flex items-center justify-center text-lg hover:bg-bg-tertiary rounded transition-colors">
                      {emoji}
                    </button>
                  ))}
                </div>
              </div>
            )}
            {CATEGORIES.map((cat) => (
              <div key={cat.name}>
                <div className="text-[10px] uppercase tracking-wider text-fg-dim px-1.5 py-1 font-semibold">
                  {cat.name}
                </div>
                <div className="flex flex-wrap">
                  {EMOJI_DATA.slice(cat.range[0], cat.range[1]).map(([emoji]) => (
                    <button key={emoji} onClick={() => handleSelect(emoji)}
                      className="w-8 h-8 flex items-center justify-center text-lg hover:bg-bg-tertiary rounded transition-colors">
                      {emoji}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </>
        )}
      </div>
    </div>
  );
}
