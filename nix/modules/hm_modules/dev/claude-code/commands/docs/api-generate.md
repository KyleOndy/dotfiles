---
allowed-tools: all
argument-hint: [--version version] [--examples data-source] [--format openapi|graphql]
description: Generate comprehensive API documentation with automatic schema extraction, example generation, and interactive documentation
---

# API Documentation

Comprehensive API documentation generation with automatic schema extraction, example generation, and interactive documentation. Creates developer-friendly documentation that stays synchronized with code changes.

## Requirements

- API documentation framework (OpenAPI, GraphQL, etc.)
- Access to API source code and schemas
- Documentation hosting and publishing platform
- Example data and test cases available

## Workflow

1. **API Discovery and Analysis**

   - Scan codebase for API endpoints and methods
   - Extract route definitions and parameters
   - Analyze request/response schemas
   - Identify authentication requirements

2. **Schema Generation**

   - Generate OpenAPI/Swagger specifications
   - Create GraphQL schema documentation
   - Extract data models and types
   - Document validation rules and constraints

3. **Example Generation**

   - Create realistic request/response examples
   - Generate code samples in multiple languages
   - Include error handling examples
   - Add authentication flow examples

4. **Interactive Documentation**

   - Set up interactive API explorer
   - Configure try-it-out functionality
   - Add mock server integration
   - Include testing playground

5. **Documentation Enhancement**

   - Add comprehensive descriptions
   - Include usage guidelines and best practices
   - Document rate limiting and quotas
   - Add troubleshooting guides

6. **Publishing and Maintenance**
   - Generate static documentation sites
   - Set up automatic updates from code
   - Configure version management
   - Enable team collaboration features

## Success Criteria

- [ ] All API endpoints documented
- [ ] Schemas accurately reflect code
- [ ] Examples are realistic and working
- [ ] Interactive features functional
- [ ] Authentication clearly explained
- [ ] Error handling documented
- [ ] Version management working
- [ ] Team can collaborate effectively

## Examples

```bash
# Generate complete API documentation
/docs:api-docs

# Generated documentation:
# - OpenAPI/Swagger specs
# - Interactive API explorer
# - Code examples
# - Authentication guides
```

```bash
# Generate docs for specific API version
/docs:api-docs --version=v2

# Version-specific documentation:
# - v2 API endpoints
# - Migration guides
# - Deprecation notices
# - Version comparison
```

```bash
# Generate docs with custom examples
/docs:api-docs --examples=production-data

# Enhanced documentation:
# - Real-world examples
# - Production use cases
# - Performance guidelines
# - Best practices
```
