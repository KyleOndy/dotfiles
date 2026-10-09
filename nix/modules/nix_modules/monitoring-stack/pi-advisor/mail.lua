-- Link text can say anything, so the URL follows it, as it would in the
-- Markdown. The scheme is ignored in the comparison so an autolinked
-- www.example.com does not print its URL twice.
local function bare(url)
  return (url:gsub("^%a[%w+.-]*:/*", ""))
end

function Link(link)
  if bare(pandoc.utils.stringify(link.content)) == bare(link.target) then
    return link
  end
  return { link, pandoc.Space(), pandoc.Code(link.target) }
end

-- A report is model output, from log lines anyone can write, so nothing in
-- its HTML may load on open: an image fetches its URL, and whatever data the
-- URL carries, without a click.
function Image(img)
  return Link(pandoc.Link(img.caption, img.src))
end

-- pandoc 3.7.0.2 passes raw HTML through even with gfm's raw_html off.
function RawInline(raw)
  return pandoc.Code(raw.text)
end

function RawBlock(raw)
  return pandoc.CodeBlock(raw.text)
end
