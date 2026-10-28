//
//  AppGuides.swift
//  HeyMate
//
//  How to use each connected app's Composio actions well (ReferenceRenderer's integration skills, in HeyMate's words).
//  A turn gets only the guides for the apps enabled in its chat.
//

import Foundation

nonisolated enum AppGuides {
    /// The guides for these Composio toolkit slugs, in a stable order; empty when none has one.
    static func text(for slugs: [String]) -> String {
        let found = slugs.sorted().compactMap { slug in guides[slug].map { "\(names[slug] ?? slug):\n\($0)" } }
        guard !found.isEmpty else { return "" }
        return "How to use the connected apps (action slugs and argument shapes; find each with COMPOSIO_SEARCH_TOOLS, run it with COMPOSIO_MULTI_EXECUTE_TOOL, and read each call's own result):\n\n"
            + found.joined(separator: "\n\n")
    }

    static let names: [String: String] = [
        "gmail": "Gmail", "googledocs": "Google Docs", "googletasks": "Google Tasks", "dropbox": "Dropbox",
        "outlook": "Outlook", "microsoft_teams": "Microsoft Teams", "linear": "Linear", "jira": "Jira",
        "clickup": "ClickUp", "hubspot": "HubSpot", "salesforce": "Salesforce",
    ]

    static let guides: [String: String] = [
        "gmail": """
        - Finding mail: GMAIL_FETCH_EMAILS {query, max_results, include_payload, verbose, page_token}. max_results is 1 unless set, so set it. List with include_payload false and verbose false (headers and snippets), then open only what you need: GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID, or a conversation with GMAIL_FETCH_MESSAGE_BY_THREAD_ID {thread_id}. "Payload is too large": drop the payload, use 25 to 50 per page, narrow the query, follow nextPageToken.
        - Query words: from:, to:, subject:, in:sent, in:inbox, -from:me, has:attachment, is:unread, "exact phrase", OR in capitals. after:/before: with dates count whole UTC days and before: excludes its day; for "yesterday" or "last week" in their time use epoch seconds (after:<start> before:<end>). Results come unsorted: sort by internalDate.
        - Counts and totals: never by eye. Page through everything, save what matters to a file with a short script, compute from it, and say how many messages you covered. A thread they replied to has a message from them later than one to them.
        - Anything outgoing starts as a draft. Reply: GMAIL_CREATE_EMAIL_DRAFT {thread_id, recipient_email, body, is_html: false} with no subject, so it stays "Re: …"; thread_id comes from the message you answer. New mail adds subject; more people go in extra_recipients. Edit with GMAIL_UPDATE_DRAFT {draft_id, thread_id, recipient_email, subject, body}, sending every field again (it rebuilds the message; without thread_id it leaves the thread); change your draft, don't make a second. Attachment: {name, mimetype, s3key} with s3key an absolute local path; if it fails, still draft and say which file to attach.
        - Send (GMAIL_SEND_DRAFT) only after they approved that exact draft. Never delete or archive mail unless asked.
        - Before saying done, read the draft back (GMAIL_GET_DRAFT {draft_id, format: "full"}) and check recipient, thread, body, attachment. Say "drafted", not "sent". Write in their tone and sign-off, with the thread's exact names, dates and times.
        """,
        "googledocs": """
        - The document_id is the part of the URL after /document/d/ up to the next /, never the whole URL. Find by title: GOOGLEDOCS_SEARCH_DOCUMENTS {query: "name contains 'words'"}.
        - Read text: GOOGLEDOCS_GET_DOCUMENT_PLAINTEXT {document_id}. Before any edit read positions: GOOGLEDOCS_GET_DOCUMENT_BY_ID {id}; each paragraph in body.content has startIndex and endIndex.
        - Add under a paragraph without touching it: GOOGLEDOCS_INSERT_TEXT_ACTION {document_id, insertion_index: that paragraph's endIndex - 1, text_to_insert: "\\n\\n<text>"} ("\\n" if the doc has no blank lines between paragraphs). Any other index lands inside a sentence. At the end: {document_id, append_to_end: true, text_to_insert}.
        - GOOGLEDOCS_UPDATE_DOCUMENT_SECTION_MARKDOWN can replace text: use it only to replace a section they named, with start_index and end_index. Change wording with GOOGLEDOCS_REPLACE_ALL_TEXT for an exact phrase; never rewrite a whole doc to change part of it.
        - New doc: GOOGLEDOCS_CREATE_DOCUMENT_MARKDOWN {title, markdown_text} (the body key is markdown_text). Success can still mean a title-only doc.
        - Before saying done, read the doc back: your text in the right place, the text around it unchanged. Give its link.
        """,
        "googletasks": """
        - No assignees, priorities, reminders or times of day, and nothing notifies anyone.
        - Everything: GOOGLETASKS_LIST_ALL_TASKS {showCompleted: false} (it includes completed ones unless told; raise max_tasks_total if truncated). Done since a date: {showCompleted: true, showHidden: true, completedMin: <UTC ISO>} (ticked in Google's apps means hidden). Lists: GOOGLETASKS_LIST_TASK_LISTS {maxResults: 100}. One list: GOOGLETASKS_LIST_TASKS {tasklist_id, maxResults: 100, pageToken}, ordered by position; follow nextPageToken. No text search: match titles yourself, and pick by id when titles repeat.
        - due is a day, stored as midnight UTC: send the day they mean ("2030-03-03"); a time is dropped, so say so. Due on a day: dueMin T00:00:00Z, dueMax T23:59:59Z. Overdue: due before today in their zone and status needsAction.
        - Every write takes the list id too; "@default" is the main list. Add: GOOGLETASKS_INSERT_TASK {tasklist_id, title, notes?, due?} (task_parent for a subtask); it isn't idempotent, so list before retrying after a timeout. Change: GOOGLETASKS_PATCH_TASK {tasklist_id, task_id, status: "completed" | "needsAction" | due | title}; notes are replaced whole, so send old plus new. Never GOOGLETASKS_UPDATE_TASK_FULL (it clears fields). Nest or move: GOOGLETASKS_MOVE_TASK {tasklist, task, parent?, previous?, destinationTasklist?}.
        - Never delete or clear tasks or lists unless asked. Before saying done, GOOGLETASKS_GET_TASK and check title, list, day, status, parent; give its webViewLink.
        """,
        "dropbox": """
        - Paths start with /, no trailing slash, root is "" (not "/"). Reuse path_display, path_lower or id (id:…) exactly as returned; typed paths fail with not_found or 409.
        - Folder: DROPBOX_LIST_FILES_IN_FOLDER {path, recursive: false}, then DROPBOX_LIST_FOLDER_CONTINUE {cursor} while has_more. Search: DROPBOX_SEARCH_FILE_OR_FOLDER {query, options: {path, file_extensions, order_by: "last_modified_time", max_results: 100}}, then again with {cursor} only. No date filter: filter server_modified (UTC) yourself. New uploads may not be indexed yet: list the folder.
        - Read: DROPBOX_READ_FILE {path} (a file reference or base64 to save first); Paper and cloud docs: DROPBOX_EXPORT_FILE. Restoring a revision overwrites the file: only when asked.
        - Save: DROPBOX_UPLOAD_FILE {path, content: {name, mimetype, s3key: absolute local path}}. The default refuses a name clash: say it exists rather than report a save; autorename true makes "name (2)"; overwrite only when they asked to replace. DROPBOX_CREATE_FOLDER: path_conflict means it exists. Rename and move are one call: DROPBOX_MOVE_FILE_OR_FOLDER {from_path, to_path} with the full new path.
        - Links are visible to others: reuse one first (DROPBOX_LIST_SHARED_LINKS {path, direct_only: true}); create one (DROPBOX_CREATE_SHARED_LINK, always with settings.audience) only when they asked for a link; without settings it is public. Never add members, delete or revoke unless asked.
        - Before saying done, DROPBOX_GET_METADATA on the result and give the path. On a 429, wait and go one write at a time.
        """,
        "outlook": """
        - Whole mailbox: OUTLOOK_SEARCH_MESSAGES {query: "from:… AND subject:\\"…\\" AND received>=2030-03-01", size: 25}; use hits[].hitId next and page with from_index while moreResultsAvailable. One folder: OUTLOOK_LIST_MESSAGES {folder, top: 50, filter: "isRead eq false and receivedDateTime ge …Z"}; top is 10 unless set and its convenience filters only cover that page, so use filter or search; follow next_page_token. Bodies: OUTLOOK_GET_MESSAGE {message_id}. Custom folder ids come from OUTLOOK_LIST_MAIL_FOLDERS; a moved message gets a new id.
        - Outgoing starts as a draft: OUTLOOK_CREATE_DRAFT_REPLY {message_id, comment} on the thread's latest message (reply-all: OUTLOOK_CREATE_ME_MESSAGE_REPLY_ALL_DRAFT {user_id: "me", message_id, comment}); new: OUTLOOK_CREATE_DRAFT {subject, body, to_recipients}. OUTLOOK_REPLY_EMAIL, OUTLOOK_SEND_EMAIL, OUTLOOK_SEND_DRAFT and OUTLOOK_FORWARD_MESSAGE send at once: only after they approved that exact draft. Recipient and category lists are replaced whole on update. Never delete mail unless asked.
        - Calendar: OUTLOOK_GET_CALENDAR_VIEW {start_datetime and end_datetime with their offset, timezone} expands repeats (OUTLOOK_LIST_EVENTS needs expand_recurring_events). Returned times have no offset: read them with start.timeZone; their zone is in their notes or OUTLOOK_GET_MAILBOX_SETTINGS. A hold: OUTLOOK_CALENDAR_CREATE_EVENT {subject, start_datetime, end_datetime (local, no offset), time_zone}. Attendees get invites: add people only when asked; changing attendees notifies them, and deleting a meeting you run cancels it for all.
        - Before saying done, read it back and check recipients, thread and times in their zone; give its webLink. Say "drafted", not "sent".
        """,
        "microsoft_teams": """
        - Work or school accounts only. Teams: MICROSOFT_TEAMS_LIST_USER_JOINED_TEAMS {user_id: "me"} (GUID ids, not names). Channels: MICROSOFT_TEAMS_TEAMS_LIST_CHANNELS {team_id}. Chats: MICROSOFT_TEAMS_CHATS_GET_ALL_CHATS {user_id: "me"}; a 1:1 chat has no topic, so filter chatType eq 'oneOnOne' and check members (MICROSOFT_TEAMS_LIST_USER_CHAT_MEMBERS). Channel and chat ids use different tools.
        - Search: MICROSOFT_TEAMS_SEARCH_MESSAGES {query (KQL), size: 25}; the id is hits[].resource.id; page with from_index.
        - Channel: MICROSOFT_TEAMS_TEAMS_LIST_CHANNEL_MESSAGES {team_id, channel_id, expand: "replies"} (without it only root posts, ordered by latest activity); one thread: MICROSOFT_TEAMS_LIST_MESSAGE_REPLIES. Chat: MICROSOFT_TEAMS_LIST_USER_CHAT_MESSAGES {user_id: "me", chat_id, orderby: "lastModifiedDateTime desc", filter: "lastModifiedDateTime gt …Z"} (the filter only works with that orderby). top is at most 50; follow next_page_token. Times are UTC; skip system event messages.
        - Posting needs their approval of that exact message; otherwise show a draft. Reply in a thread: MICROSOFT_TEAMS_POST_MESSAGE_REPLY {team_id, channel_id, message_id: root id, content}; MICROSOFT_TEAMS_TEAMS_POST_CHANNEL_MESSAGE always starts a new thread. Chat: MICROSOFT_TEAMS_TEAMS_POST_CHAT_MESSAGE {chat_id, content}. content_type is "text" unless "html"; typing @Name notifies nobody (a real mention needs html and a mentions entry): mention only when asked. Never edit or delete messages, channels or members unless asked.
        - Before saying done, read the post back and check it is in the right thread or chat. "Posted" only after a send.
        """,
        "linear": """
        - Prefer the typed actions; LINEAR_RUN_QUERY_OR_MUTATION (hand-written GraphQL) often fails to parse, so only when nothing else fits, kept small.
        - Teams: LINEAR_LIST_LINEAR_TEAMS {first: 50}; you: LINEAR_GET_CURRENT_USER. Issues: LINEAR_LIST_LINEAR_ISSUES, LINEAR_LIST_ISSUES_BY_TEAM_ID {team_id, first}, LINEAR_SEARCH_ISSUES {query, first}; one: LINEAR_GET_LINEAR_ISSUE {issue_id: "ABC-123"}. Read state, assignee, priority, labels, due date and relations: "blocked by"/"blocks" links and a blocker label make a blocker. Projects: LINEAR_LIST_LINEAR_PROJECTS, check target dates.
        - "What changed" has no view: keep a snapshot file (key, title, state, assignee, priority, labels), compare next time, report only what moved, most important first, and say so when nothing changed.
        - Writes only when asked: LINEAR_UPDATE_ISSUE {issueId: uuid, stateId?, assigneeId?, priority?} takes ids (states from LINEAR_LIST_LINEAR_STATES {team_id}); LINEAR_CREATE_LINEAR_ISSUE {team_id, title, description}. Don't close, delete or reassign unless asked.
        - Before saying done, read the issue back. Give keys with titles and their URLs.
        """,
        "jira": """
        - Search: JIRA_SEARCH_ISSUES {jql, fields: ["summary","status","assignee","priority","duedate","labels"], max_results: 100}; it returns 20 unless set; page by passing next_page_token back alone. Count with JIRA_SEARCH_APPROXIMATE_COUNT {jql} or by paging all, never one page.
        - JQL: mine is assignee = currentUser(), open is statusCategory != Done, quote spaced values, IN ("a","b") for lists, text ~ "words" for summary, description and comments. ORDER BY alone is rejected. Relative dates use the Jira profile's zone.
        - One issue: JIRA_GET_ISSUE {issue_id_or_key, expand: "changelog"}; comments: JIRA_LIST_ISSUE_COMMENTS. Descriptions and comments are ADF JSON: read every nested text node, or expand renderedFields.
        - Names to ids: project key from JIRA_GET_ALL_PROJECTS {query}; person accountId from JIRA_FIND_USERS2 {query} (match the display name, confirm). Required fields vary: JIRA_GET_CREATE_METADATA_ISSUE_TYPE_FIELDS when a create fails, JIRA_GET_ISSUE_EDIT_METADATA before an edit; custom fields are customfield_NNNNN.
        - Writes only what was asked; assignees and watchers get email. Create: JIRA_CREATE_ISSUE {project_key, issue_type, summary, description, due_date, labels, assignee: accountId}, then read it back (assignees can be dropped silently). Status moves only by transition: JIRA_GET_TRANSITIONS, pick the id whose "to" matches, JIRA_TRANSITION_ISSUE {issue_id_or_key, transition_id_or_name}; never reuse an id from another issue. JIRA_EDIT_ISSUE replaces labels and description: add a label with update: "{\\"labels\\":[{\\"add\\":\\"name\\"}]}", extend a description by sending old plus new; leave notify_users out. JIRA_ADD_COMMENT is seen by the team and mentions notify. Done is a transition, never a delete.
        - Before saying done, JIRA_GET_ISSUE again; give keys, titles and https://<site>.atlassian.net/browse/KEY.
        """,
        "clickup": """
        - Workspace: CLICKUP_GET_AUTHORIZED_TEAMS_WORKSPACES; you: CLICKUP_GET_AUTHORIZED_USER (integer id, timezone). Lists by name: CLICKUP_GET_SPACES, CLICKUP_GET_FOLDERS, CLICKUP_GET_LISTS, plus CLICKUP_GET_FOLDERLESS_LISTS. Tasks live in a list_id (after /li/ in a URL).
        - Across the workspace: CLICKUP_GET_FILTERED_TEAM_TASKS {team_Id (capital I), assignees, due_date_lt, include_closed, subtasks: true, page}; one list: CLICKUP_GET_TASKS {list_id, page}; up to 100 a page until last_page. No text search. Closed tasks and subtasks are hidden by default: retry with include_closed and subtasks before saying not found. A filter that doesn't match exactly returns empty, not an error. One task: CLICKUP_GET_TASK {task_id} (custom ids like ABC-123 need custom_task_ids and team_id).
        - Statuses are per list and case-sensitive (CLICKUP_GET_LIST → statuses); closing means the status of type "closed". Priority 1 urgent to 4 low. Dates are Unix milliseconds; for an all-day date send the day's local noon, never UTC midnight; convert returned dates.
        - Writes only what was asked; assignees and watchers are notified. CLICKUP_CREATE_TASK {list_id, name, description, priority, due_date, due_date_time: false, assignees: [int ids from CLICKUP_GET_LIST_MEMBERS]}. CLICKUP_UPDATE_TASK replaces what it sends (read a description before extending it); assignees change only with assignees__add/assignees__rem. Comment: CLICKUP_CREATE_TASK_COMMENT {task_id, comment_text, assignee: your id, notify_all: false}. Close by status, never CLICKUP_DELETE_TASK.
        - Before saying done, CLICKUP_GET_TASK again; give the task url.
        """,
        "hubspot": """
        - Properties use internal names (dealname, closedate, hubspot_owner_id), never labels.
        - Search: HUBSPOT_SEARCH_CRM_OBJECTS_BY_CRITERIA {objectType, filterGroups, properties, sorts, limit: 100, after}; the per-object search tools return 5 unless set, so set limit and follow paging.next.after to the end. Name every property you'll report. Filters in a group are AND, OR is separate groups; linked records: {propertyName: "associations.contact", operator: "EQ", value: id}. Never count or total from one page: save rows and compute.
        - One record: HUBSPOT_READ_CRM_OBJECT_BY_ID {objectType, objectId, properties, associations} (a contact by email: idProperty "email"). Notes on a record: search objectType "notes" with the association filter and hs_note_body, hs_timestamp.
        - Labels aren't ids: stage ids from HUBSPOT_RETRIEVE_PIPELINE_STAGES in the deal's own pipeline; owner id from HUBSPOT_RETRIEVE_OWNERS; option values from HUBSPOT_READ_A_CRM_PROPERTY_BY_NAME. Date filters take epoch milliseconds as strings, computed in their zone.
        - Writes: HUBSPOT_UPDATE_DEAL {dealId, properties}; others HUBSPOT_PARTIALLY_UPDATE_CRM_OBJECT_BY_ID. HUBSPOT_CREATE_NOTE and HUBSPOT_CREATE_TASK need associations or they float unattached (note→contact 202, →deal 214; task→contact 204, →deal 216, →company 192). Giving a record to another owner can notify them: only when asked. Never archive, merge or delete unless asked.
        - Search lags: before saying done read the record by id with what you set; link it.
        """,
        "salesforce": """
        - Read with SALESFORCE_RUN_SOQL_QUERY {query} using API names (custom fields end __c, their lookups __r.Name; unsure: SALESFORCE_GET_ALL_FIELDS_FOR_OBJECT). Strings and ids in single quotes, dates unquoted, no AS (SUM(Amount) total … GROUP BY). Read composio_execution_message for rewrites. Page with SALESFORCE_QUERY_MORE {next_records_url} until done. The search tools return 50 and match loosely: set limit and confirm the record. Never count by eye; empty can mean they can't see the records.
        - Date literals (TODAY, THIS_QUARTER, LAST_N_DAYS:n) use the Salesforce user's zone; CloseDate and ActivityDate are plain dates; CreatedDate and LastModifiedDate need a datetime with their offset. Returned datetimes are UTC.
        - Writes only what was asked: SALESFORCE_UPDATE_OPPORTUNITY {opportunity_id, stage_name?, amount?, close_date?, next_step?} (stage values valid for its record type: SALESFORCE_GET_PICKLIST_VALUES_BY_RECORD_TYPE; "" means unchanged, clear with SALESFORCE_SOBJECT_ROWS_UPDATE and null). SALESFORCE_CREATE_TASK {subject, who_id (contact 003, lead 00Q), what_id (account 001, opportunity 006, case 500), activity_date}; SALESFORCE_LOG_CALL; SALESFORCE_CREATE_NOTE doesn't dedupe, so don't retry blindly. SALESFORCE_SEND_EMAIL sends at once: only after they approved that exact draft. Never delete, reassign or add to campaigns unless asked.
        - Before saying done, read it back by id and check fields, links and dates.
        """,
    ]
}
