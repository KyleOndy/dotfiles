---
allowed-tools: Read, LS
model: claude-3-5-haiku-20241022
description: Display detailed information about the active requirement gathering session
---

# View Current Requirement

Display detailed information about the active requirement gathering session, including progress, answers, and next steps.

## Workflow

1. **Check Active Requirement Status**
   - Read requirements/.current-requirement file
   - Verify if requirement gathering is active
   - Show "No active requirement" if none exists

2. **Load Requirement Data**
   - Read all files from active requirement folder
   - Parse metadata.json for status and progress
   - Extract phase information and timestamps

3. **Display Comprehensive Status**
   - Show requirement name and duration
   - Display current phase and progress metrics
   - Present initial request and codebase overview

4. **Show Question/Answer History**
   - Display completed discovery questions and answers
   - Show targeted context findings if available
   - Present expert requirements questions and answers

5. **Indicate Next Steps**
   - Suggest continuation with /requirements-status
   - Offer early completion with /requirements-end
   - Provide phase-appropriate guidance

## File Structure

- 00-initial-request.md - Original user request
- 01-discovery-questions.md - Context discovery questions
- 02-discovery-answers.md - User's answers
- 03-context-findings.md - AI's codebase analysis
- 04-detail-questions.md - Expert requirements questions
- 05-detail-answers.md - User's detailed answers
- 06-requirements-spec.md - Final requirements document

## Display Format

```
📋 Current Requirement: [name]
⏱️  Duration: [time since start]
📊 Phase: [Initial Setup/Context Discovery/Targeted Context/Expert Requirements/Complete]
🎯 Progress: [total answered]/[total questions]

📄 Initial Request:
[Show content from 00-initial-request.md]

🏗️ Codebase Overview (Phase 1):
- Architecture: [e.g., React + Node.js + PostgreSQL]
- Main components: [identified services/modules]
- Key patterns: [discovered conventions]

✅ Context Discovery Phase (5/5 complete):
Q1: Will users interact through a visual interface? YES
Q2: Does this need to work on mobile? YES
Q3: Will this handle sensitive data? NO
Q4: Do users have a current workaround? YES (default)
Q5: Will this need offline support? IDK → NO (default)

🔍 Targeted Context Findings:
- Specific files identified: [list key files]
- Similar feature: UserProfile at components/UserProfile.tsx
- Integration points: AuthService, ValidationService
- Technical constraints: Rate limiting required

🎯 Expert Requirements Phase (2/8 answered):
Q1: Use existing ValidationService at services/validation.ts? YES
Q2: Extend UserModel at models/User.ts? YES
Q3: Add new API endpoint to routes/api/v1? [PENDING]
...

📝 Next Action:
- Continue with /requirements-status
- End early with /requirements-end
```

## Important

- This is view-only (doesn't continue gathering)
- Shows complete history and context
- Use /requirements-status to continue
