# Canonical Requirements

Generated from spec files. Each requirement has a unique hash-based ID.

## Requirements

- [node-1f540d2c] the system shall primary capability
- [node-8330b04e] the system shall secondary capability
- [node-03ef4d25] must not exceed limitation
- [node-09daab1c] must support minimum requirement

## Definitions

- [node-6ab64ae1] term means clear definition

## Phoenix Requirements

- [node-aa6fe46a] on app mount the app must first attempt to load stored credentials using loadsavedcredentials before checking selfappstatesessionauthenticated
- [node-cd651a59] on app mount if stored credentials are found and valid the app must autopopulate the session and skip showing authscreen entirely
- [node-75b072bf] on app mount the onmount method must call loadsavedcredentials and if it returns valid data immediately set sessionauthenticatedtrue and populate session with stored handle did nick webtoken
- [node-886f6d89] the onmount method must log authmount starting onmount at the beginning to enable debugging
- [node-d44c672d] the onmount method must log whether saved credentials were found with authmount saved credentials found truefalse
- [node-17c03e58] when autologin succeeds the app must log authmount autologin complete so users can verify the flow worked
- [node-9ab8c582] the freeqapp class must implement savecredentialshandle did nick webtoken method that saves credentials to configfreeqauthjson
- [node-4c082630] the savecredentials method must create the configfreeq directory if it does not exist
- [node-b210cb48] the savecredentials method must save a json file with fields handle did nick webtoken timestamp
- [node-a2d07973] on authcompleted the app must call savecredentials to persist credentials for future autologin
- [node-506aa018] the system must use at protocol oauth via freeqauthbroker for authentication
- [node-b4402a28] on app mount the app must check for stored authentication credentials and autologin if valid credentials exist
- [node-90b2f2f6] the system must persist authentication credentials webtoken handle did nick to configfreeqauthjson after successful login
- [node-a5ed0034] credentials must always be saved automatically after successful authentication no checkbox needed
- [node-0e795028] credentials must be saved immediately after successful authentication
- [node-88b2976a] the freeqapp class must implement savechannels method that saves joined channels to configfreeqsessionjson
- [node-17c917a5] the savechannels method must save a json file with field channels containing a list of joined channel names eg general help
- [node-1626593b] the freeqapp class must implement loadchannels method that loads saved channels from configfreeqsessionjson
- [node-46330d6b] on app mount after authentication succeeds the app must call loadchannels to restore previously joined channels
- [node-16523444] when channels are loaded the app must populate appstatebuffers with a bufferstate for each saved channel so they appear in the sidebar immediately
- [node-e6aa0806] on app unmount or when channels change the app must call savechannels to persist the current channel list
- [node-5e0e56e9] the session storage directory configfreeq must be created if it does not exist when saving channels
- [node-e595e2c9] on app startup the app must load stored credentials from configfreeqauthjson and validate the webtoken with the broker
- [node-7ae921b2] if stored credentials are invalid or expired the app must show authscreen for reauthentication
- [node-c020b58c] the stored credentials must include handle did nickname webtoken and timestamp
- [node-19fdfbf4] the auth storage directory configfreeq must be created if it does not exist
- [node-d9af2095] authscreen must provide a clear saved login option for users to remove stored credentials
- [node-0a5f52d4] on app mount if not authenticated the app must push authscreen modalscreen to cover entire terminal
- [node-d2b17611] authscreen must display a prominent connect button with idconnectbutton that is always visible when auth status is not polling
- [node-2c33febc] authscreen must open browser immediately when connect button pressed using webbrowseropen
- [node-59dee27c] authscreen must poll for oauth completion in background thread and call onauthcomplete when result received
- [node-507a5d07] authscreen must post authcompleted message with handle did nick brokertoken on successful authentication
- [node-fc52514b] authscreen must call selfdismiss immediately after posting authcompleted message to close the modal screen
- [node-0700ec73] on guestmoderequested the app must populate appstatebuffers with at least one default buffer so ui shows content immediately
- [node-072adb64] on guestmoderequested the app must set appstateuiactivebufferid to the first available buffer so widgets know which buffer to display
- [node-702fe5c5] on guestmoderequested the app must populate appstatechannels with a default channel containing a guest user so userlist shows content
- [node-e46b05d2] authscreen must post guestmoderequested message when guest mode selected
- [node-bdf09952] all event messages must inherit from textualmessagemessage and call superinit
- [node-b782e6c8] authscreen must dismiss itself after posting completion message textual pattern
- [node-49bd657d] the user model fields are nick ident host realname atprotohandle modes
- [node-ed53f4ea] the message model fields are id sender target content timestamp edited edithistory streaming reactions tags msgid replyto replycount batchid
- [node-908b31e1] when creating user instances code must use the exact field names from the model nick not nickname or id atprotohandle not handle
- [node-de968fc4] when creating message instances code must use the exact field names from the model target not channelid sender not senderid timestampdatetimenow not isoformat string
- [node-00609785] the main ui layout sidebar main content user list must be hidden during authentication only the auth screen visible
- [node-ed81a1ef] when authentication completes the main ui layout must become visible by setting widgetvisible true on all regions
- [node-afa0b8b7] on authcompleted populatedefaultdata must create a new buffers dict not mutate existing to trigger buffersidebarwatchbuffers reactive update
- [node-08583676] the populatedefaultdata method must use selfappstatebuffers console buffer new dict not selfappstatebuffersconsole buffer mutation
- [node-e6bcffa7] on authcompleted the app must populate appstatebuffers with at least one default buffer eg console or general so the ui has content to display
- [node-c7e70dd1] on authcompleted the app must set appstateuiactivebufferid to the first available buffer so widgets know which buffer to display
- [node-e1ee2c9e] all widgets buffersidebar messagelist userlist must react to appstate changes by implementing watch methods for their reactive data
- [node-f803e53f] the app must call widgetrefresh or update reactive properties after auth completes to trigger widget rerendering with new data
- [node-ed95a1fd] buffersidebar must implement watchbuffers to rerender when buffers change
- [node-bf994800] when authentication completes the app must explicitly call sidebarupdatebuffersappstatebuffers to force the sidebar to rerender with the newly populated channel list
- [node-29f85ffb] the buffersidebar must be explicitly refreshed after populatedefaultdata is called because the reactive buffers dict reference does not trigger watchbuffers when mutated
- [node-e1f08633] when autologin completes in onmount the app must explicitly call buffersidebarwatchbuffersappstatebuffers to force sidebar refresh because textual compose runs before onmount and sidebar was composed with empty buffers
- [node-d412194c] when authcompleted fires the app must explicitly call buffersidebarwatchbuffersappstatebuffers after populatedefaultdata to ensure sidebar shows populated buffers
- [node-875ea8b6] when guest mode starts the app must explicitly call buffersidebarwatchbuffersappstatebuffers after populatedefaultdata to ensure sidebar shows guest buffers
- [node-73f44b63] messagelist must implement watchmessages or watch the active buffer to rerender when messages change
- [node-06aa548a] userlist must implement watchusers to rerender when users change
- [node-c8d3e822] the header and footer must be hidden during authentication and visible after authentication completes
- [node-77eff8b8] visibility must be controlled by python widgetvisible property not css display classes css descendant selectors are unreliable in textual
- [node-2848d1ea] the auth screen must use modalscreen for true fullscreen coverage covers docked headerfooter widgets
- [node-2c760e46] on authcompleted message the app must update state pop auth screen set all region widgets visibletrue and focus input bar
- [node-43cb8709] the updateuifromstate method must check ismounted before accessing children to avoid lifecycle errors
- [node-c385163a] widget initialization must accept id classes kwargs and pass to superinit
- [node-f76639d2] textuals input widget does not accept a multiline parameter do not pass multilinetruefalse to input
- [node-56cd806b] all textual messages must call superinit in their init method
- [node-bede3741] when importing both textuals message event class and a chat message model textuals message must be aliased eg from textualmessage import message as textualmessage to avoid name collision event message classes must inherit from textualmessage not the chat message model
- [node-5b3f1747] the apppy must include entry point block if name main runapp for python m srcgeneratedapp to work
- [node-e11b2ced] buffersidebar must visually indicate the currently activeselected channel with distinct styling highlight accent color or marker when appstateuiactivebufferid is set
- [node-fafbc401] buffersidebar must implement watchactivebuffer or react to activebufferid changes to update the visual selection indicator immediately when the user selects a different channel
- [node-1dc9e86a] the selected channel indicator must be clearly visible and distinguishable from unselected channels using css classes eg selected active applied to the channel list item
- [node-19decd68] channel selection indicator update

## App Lifecycle Requirements

- [node-0abc3262] freeqapp must store the setinterval timer handle in selfpolltimer when starting irc message polling this is required to cancel the timer on exit
- [node-cfdb499e] freeqapp onunmount must stop the irc polling timer before disconnecting the client call selfpolltimerstop to prevent the repeating timer from keeping the event loop alive when user exits with ctrlq or ctrlc
- [node-9b72066f] freeqapp onunmount must disconnect the irc client to prevent hang on exit call selfclientdisconnect after stopping the polling timer
- [node-c0fe61db] freeqapp must reduce logging overhead by logging poll events at debug level instead of info level only log important irc events message privmsg notice join part at info level this prevents io blocking that was causing ui to freeze

## Part 2: Implementation Guidance (Python/Textual)

- [node-7aa13656] the bufferstate dataclass must include a scrollposition field with type float and default value 00 to track the users scroll position in each buffer

## Message Sending Requirements (Optimistic UI)

- [node-aaf8574e] when handlesubmit sends a message via clientsendmessage it must immediately append the message to the target buffer using appendline before waiting for server response
- [node-1a5715cd] the optimistic message must use the current clients nickname as sender
- [node-008da267] the optimistic message must be assigned a temporary msgid for tracking and deduplication
- [node-ab42a071] the implementation must call renderactivebuffer immediately after appending the optimistic message
- [node-47d3c4b7] when a server message echo is received the handler must detect if it matches a pending optimistic message by comparing sender nickname and content hash
- [node-9f60fc3f] if a matching optimistic message is found the handler must skip appending a duplicate line and update the messageindex entry with the serverassigned msgid
- [node-fbf0cc73] see optimisticuiimplementationmd for complete implementation details

## MessageWidget Implementation Requirements

- [node-b42b3514] messagewidget must use static widget for avatar with richtext styling instead of label with style parameter textuals label widget does not accept a style parameter use statictextchar stylefbold white on color classesavatar instead of labelchar stylefbackground color
- [node-def7c33f] messagewidget must not use method name rendercontent as it conflicts with textuals internal widget rendering method use formatmessagecontent instead to avoid typeerror messagewidgetrendercontent missing 1 required positional argument error
- [node-500f5a09] messagewidget must extend widget not static when using compose with containers static is for simple content via render method containers like horizontalvertical require the widget base class with compose pattern
- [node-f68d1a91] messagewidget must use semantic layout with minimal css structure avatar content column where content meta row body reactions let textuals default sizing height auto width 1fr handle layout rather than explicit margins and padding define what semantic roles avatar meta body reacts not how explicit pixelcharacter sizing

## Layout Requirements (Fractional Sizing)

- [node-cb18d327] layout must use percentages reflecting the 161 ratio sidebar 12 main content 76 user list 12 this gives message content 6x the space of each sidebar
- [node-f75dd72e] messagelist css height must be 1fr not 100 using height 100 causes messagelist to take all available space in vertical container pushing inputbar out of view using height 1fr allows messagelist to take remaining space while inputbar gets its natural height
- [node-6bcd6b4b] messagelist must implement incremental message updates in refreshmessages instead of removechildren remounting all widgets which blocks ui for 16 seconds with 20 messages only add new message widgets that dont exist yet preserve existing widgets and only mount new ones
- [node-dbd65556] messagelist refreshmessages must batch widget creation for performance create all messagewidget instances first then mount them in a loop rather than interleaving creation and mounting
- [node-3488aa1d] messagelist refreshmessages must show all messages in the buffer not just those within visiblerange the visiblerange is for virtualization optimization but new messages must always be mounted regardless of scroll position use targetmessages selfmessages not selfmessagesstartend

## Sidebar Display Requirements

- [node-5df2a612] buffersidebar must prevent double in channel names when displaying channel type buffers only add prefix if buffername does not already start with this prevents test when buffername is already test

## AuthScreen UX Requirements

- [node-c60d2e47] authscreen must support enter key to submit auth form users can type their handle and press enter instead of clicking connect button implement oneventskey handler that calls startauthentication when eventkey enter
- [node-4ecf2de3] authscreen must not show remember login checkbox credentials must always be saved automatically after successful authentication no checkbox needed this simplifies ux and reduces user confusion
