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
- [node-8434d139] authscreen must show a remember login checkbox that defaults to checked
- [node-b6c49316] when remember login is enabled credentials must be saved immediately after successful authentication
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
- [node-5b3f1747] the apppy must include entry point block if name main runapp for python m srcgeneratedapp to work
