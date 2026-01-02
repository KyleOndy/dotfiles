---
allowed-tools: Read, Write, Edit, LS, WebFetch, AskUserQuestion
argument-hint: [--highlight-features] [--audience developers|users]
description: Maintain comprehensive README with automatic content generation, project analysis, and documentation best practices
---

# Update README

Comprehensive README maintenance with automatic content generation, project analysis, and documentation best practices. Ensures README stays current with project changes and provides excellent developer experience.

## Requirements

- Access to project files and structure
- Package management files (package.json, requirements.txt, etc.)
- CI/CD configuration and badges
- License and contribution guidelines

## Workflow

### Initial Setup

**Determine target audience:**

If no `--audience` argument was provided, use the AskUserQuestion tool:

**Question:** "Who is the primary audience for this README?"
**Header:** "Audience"
**Options:**

- Label: "Both developers and users (Recommended)"
  Description: "Balanced README with installation, usage, and development info"
- Label: "End users only"
  Description: "Focus on installation, usage, and features"
- Label: "Developers only"
  Description: "Focus on architecture, development setup, and contributing"

**Handle responses:**

- "Both developers and users" → Include all sections (installation, usage, development)
- "End users only" → Focus on installation, usage examples, and features
- "Developers only" → Focus on architecture, development setup, API docs, contributing

**Determine sections to update:**

Use the AskUserQuestion tool to select which sections need updating:

**Question:** "Which sections of the README should be updated?"
**Header:** "Sections"
**Options:**

- Label: "All sections (Recommended)"
  Description: "Comprehensive update of entire README"
- Label: "Project description and features"
  Description: "Update overview, purpose, and feature list"
- Label: "Installation and setup"
  Description: "Update installation instructions and dependencies"
- Label: "Usage and examples"
  Description: "Update code examples and usage guides"
- Label: "Contributing and development"
  Description: "Update development setup and contribution guidelines"

**Handle responses:**

- "All sections" → Perform comprehensive update (all steps)
- "Project description and features" → Focus on steps 2 (Content Structure) and 3 (Badges)
- "Installation and setup" → Focus on step 2 and verify installation instructions
- "Usage and examples" → Focus on step 2 and update examples
- "Contributing and development" → Focus on step 5 (Contribution Guidelines)

### Update Steps

1. **Project Analysis**
   - Scan project structure and files
   - Identify key technologies and frameworks
   - Analyze build and deployment processes
   - Extract project metadata and dependencies

2. **Content Structure Generation**
   - Create comprehensive table of contents
   - Generate project description and purpose
   - Add installation and setup instructions
   - Include usage examples and tutorials

3. **Badge and Status Integration**
   - Add CI/CD pipeline status badges
   - Include code coverage and quality badges
   - Add dependency status indicators
   - Include license and version badges

4. **Documentation Links**
   - Link to detailed documentation
   - Add API documentation references
   - Include changelog and release notes
   - Link to issue tracker and discussions

5. **Contribution Guidelines**
   - Add contribution instructions
   - Include code of conduct
   - Document development setup
   - Add pull request guidelines

6. **Maintenance and Updates**
   - Verify all links are working
   - Update screenshots and examples
   - Refresh dependency information
   - Validate installation instructions

## Success Criteria

- [ ] README reflects current project state
- [ ] Installation instructions work
- [ ] All links are functional
- [ ] Examples are up-to-date
- [ ] Badges show correct status
- [ ] Contribution guidelines clear
- [ ] Project purpose well explained
- [ ] Documentation structure logical

## Examples

```bash
# Update README with current project state
/docs:update-readme

# Updated sections:
# - Project description
# - Installation instructions
# - Usage examples
# - Contributing guidelines
```

```bash
# Update README with new feature highlights
/docs:update-readme --highlight-features

# Feature-focused update:
# - New feature descriptions
# - Updated examples
# - Enhanced screenshots
# - Migration guides
```

```bash
# Update README for specific audience
/docs:update-readme --audience=developers

# Developer-focused update:
# - Technical details
# - Architecture overview
# - Development setup
# - API references
```
