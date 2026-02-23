# frozen_string_literal: true

module Przn
  class PdfExporter
    PAGE_WIDTH  = 960
    PAGE_HEIGHT = 540
    BG_COLOR    = '1e1e2e'
    FG_COLOR    = 'cdd6f4'

    SCALE_TO_PT = {
      1 => 10, 2 => 18, 3 => 24, 4 => 32,
      5 => 40, 6 => 48, 7 => 56,
    }.freeze

    DEFAULT_SCALE = Renderer::DEFAULT_SCALE

    COLOR_MAP = {
      'red' => 'FF5555', 'green' => '50FA7B', 'yellow' => 'F1FA8C', 'blue' => '6272A4',
      'magenta' => 'FF79C6', 'cyan' => '8BE9FD', 'white' => 'F8F8F2',
      'bright_red' => 'FF6E6E', 'bright_green' => '69FF94', 'bright_yellow' => 'FFFFA5',
      'bright_blue' => 'D6ACFF', 'bright_magenta' => 'FF92DF', 'bright_cyan' => 'A4FFFF',
      'bright_white' => 'FFFFFF',
    }.freeze

    CODE_BG = '313244'
    DIM_COLOR = '6c7086'

    def initialize(presentation, base_dir: '.')
      @presentation = presentation
      @base_dir = base_dir
    end

    # Prawn's ttfunk requires TrueType outlines (glyf table), not CFF-based fonts
    FONT_SEARCH_PATHS = [
      -> { File.join(Dir.home, 'Library/Fonts/NotoSansJP-Regular.ttf') },
      -> { Dir.glob('/usr/share/fonts/**/NotoSansCJK-Regular.ttc').first },
      -> { Dir.glob('/usr/share/fonts/**/NotoSansJP-Regular.ttf').first },
      -> { File.join(Dir.home, 'Library/Fonts/HackGen-Regular.ttf') },
      -> { '/Library/Fonts/Arial Unicode.ttf' },
      -> { '/System/Library/Fonts/Supplemental/Arial Unicode.ttf' },
    ].freeze

    def export(output_path)
      require 'prawn'

      pdf = Prawn::Document.new(
        page_size: [PAGE_WIDTH, PAGE_HEIGHT],
        margin: 0,
      )

      register_fonts(pdf)

      @presentation.slides.each_with_index do |slide, si|
        pdf.start_new_page unless si == 0
        render_slide(pdf, slide, si)
      end

      pdf.render_file(output_path)
    end

    private

    def register_fonts(pdf)
      font_path = find_cjk_font
      return unless font_path

      if font_path.end_with?('.ttc')
        pdf.font_families.update(
          'CJK' => {
            normal: {file: font_path, font: 0},
            bold:   {file: font_path.sub('W3', 'W6').then { |p| File.exist?(p) ? p : font_path }, font: 0},
            italic: {file: font_path, font: 0},
          }
        )
      else
        bold_path = font_path.sub(/Regular|Medium/, 'Bold').sub(/-[^-]*\./, '-Bold.')
        bold_path = font_path unless File.exist?(bold_path)
        pdf.font_families.update(
          'CJK' => {
            normal: font_path,
            bold:   bold_path,
            italic: font_path,
          }
        )
      end

      pdf.font 'CJK'
      @font_registered = true
    end

    def find_cjk_font
      FONT_SEARCH_PATHS.each do |finder|
        path = finder.call
        return path if path && File.exist?(path)
      end
      nil
    end

    def render_slide(pdf, slide, slide_index)
      draw_background(pdf)

      margin_x = PAGE_WIDTH / 16.0
      content_width = PAGE_WIDTH - margin_x * 2

      if slide_index == 0
        # Title slide: vertically center
        total_h = estimate_slide_height(slide, content_width, pdf)
        y = (PAGE_HEIGHT + total_h) / 2.0
      else
        y = PAGE_HEIGHT - 20
      end

      pending_align = nil
      slide.blocks.each do |block|
        if block[:type] == :align
          pending_align = block[:align]
        else
          y = render_block(pdf, block, margin_x, content_width, y, align: pending_align)
          pending_align = nil
        end
      end

      # Page number
      total = @presentation.total
      status = "#{slide_index + 1} / #{total}"
      pdf.fill_color DIM_COLOR
      pdf.text_box status, at: [0, 16], width: PAGE_WIDTH - 10, height: 14, size: 8, align: :right
      pdf.fill_color FG_COLOR
    end

    def draw_background(pdf)
      pdf.canvas do
        pdf.fill_color BG_COLOR
        pdf.fill_rectangle [0, PAGE_HEIGHT], PAGE_WIDTH, PAGE_HEIGHT
      end
      pdf.fill_color FG_COLOR
    end

    def render_block(pdf, block, margin_x, content_width, y, align: nil)
      case block[:type]
      when :heading         then render_heading(pdf, block, margin_x, content_width, y)
      when :paragraph       then render_paragraph(pdf, block, margin_x, content_width, y, align: align)
      when :code_block      then render_code_block(pdf, block, margin_x, content_width, y)
      when :unordered_list  then render_unordered_list(pdf, block, margin_x, content_width, y)
      when :ordered_list    then render_ordered_list(pdf, block, margin_x, content_width, y)
      when :definition_list then render_definition_list(pdf, block, margin_x, content_width, y)
      when :blockquote      then render_blockquote(pdf, block, margin_x, content_width, y)
      when :table           then render_table(pdf, block, margin_x, content_width, y)
      when :image           then render_image(pdf, block, margin_x, content_width, y)
      when :blank           then y - SCALE_TO_PT[DEFAULT_SCALE]
      else y - SCALE_TO_PT[DEFAULT_SCALE]
      end
    end

    def render_heading(pdf, block, margin_x, content_width, y)
      text = block[:content]
      if block[:level] == 1
        scale = KittyText::HEADING_SCALES[1]
        pt = SCALE_TO_PT[scale]
        formatted = build_formatted_text(text, pt)
        pdf.formatted_text_box formatted, at: [margin_x, y], width: content_width, align: :center, overflow: :shrink_to_fit
        y - pt - heading_margin(pt)
      else
        pt = SCALE_TO_PT[DEFAULT_SCALE]
        prefix = [{text: "\u30FB", size: pt, color: FG_COLOR, styles: [:bold]}]
        formatted = prefix + build_formatted_text(text, pt)
        pdf.formatted_text_box formatted, at: [margin_x, y], width: content_width, overflow: :shrink_to_fit
        y - pt - 4
      end
    end

    def render_paragraph(pdf, block, margin_x, content_width, y, align: nil)
      text = block[:content]
      scale = max_inline_scale(text) || DEFAULT_SCALE
      pt = SCALE_TO_PT[scale]
      formatted = build_formatted_text(text, pt)
      align_sym = align || :left

      pdf.formatted_text_box formatted, at: [margin_x, y], width: content_width, align: align_sym, overflow: :shrink_to_fit
      y - pt - 2
    end

    def render_code_block(pdf, block, margin_x, content_width, y)
      code_lines = block[:content].lines.map(&:chomp)
      return y - SCALE_TO_PT[DEFAULT_SCALE] if code_lines.empty?

      pt = SCALE_TO_PT[DEFAULT_SCALE] * 0.7
      line_height = pt * 1.4
      padding = 8
      box_height = code_lines.size * line_height + padding * 2

      # Draw background
      pdf.fill_color CODE_BG
      pdf.fill_rounded_rectangle [margin_x, y], content_width, box_height, 4
      pdf.fill_color FG_COLOR

      code_y = y - padding
      code_lines.each do |line|
        pdf.text_box line, at: [margin_x + padding, code_y], width: content_width - padding * 2, height: line_height, size: pt, color: FG_COLOR, overflow: :shrink_to_fit
        code_y -= line_height
      end

      y - box_height - 6
    end

    def render_unordered_list(pdf, block, margin_x, content_width, y)
      pt = SCALE_TO_PT[DEFAULT_SCALE]
      block[:items].each do |item|
        depth = item[:depth] || 0
        indent = depth * pt
        prefix = [{text: "\u30FB", size: pt, color: FG_COLOR}]
        formatted = prefix + build_formatted_text(item[:text], pt)
        pdf.formatted_text_box formatted, at: [margin_x + indent, y], width: content_width - indent, overflow: :shrink_to_fit
        y -= pt + 6
      end
      y
    end

    def render_ordered_list(pdf, block, margin_x, content_width, y)
      pt = SCALE_TO_PT[DEFAULT_SCALE]
      block[:items].each_with_index do |item, i|
        depth = item[:depth] || 0
        indent = depth * pt
        prefix = [{text: "#{i + 1}. ", size: pt, color: FG_COLOR}]
        formatted = prefix + build_formatted_text(item[:text], pt)
        pdf.formatted_text_box formatted, at: [margin_x + indent, y], width: content_width - indent, overflow: :shrink_to_fit
        y -= pt + 6
      end
      y
    end

    def render_definition_list(pdf, block, margin_x, content_width, y)
      pt = SCALE_TO_PT[DEFAULT_SCALE]

      # Term (bold)
      formatted = build_formatted_text(block[:term], pt).map { |f| f.merge(styles: (f[:styles] || []) + [:bold]) }
      pdf.formatted_text_box formatted, at: [margin_x, y], width: content_width, overflow: :shrink_to_fit
      y -= pt + 2

      # Definition (indented)
      indent = pt * 1.5
      block[:definition].each_line do |line|
        formatted = build_formatted_text(line.chomp, pt)
        pdf.formatted_text_box formatted, at: [margin_x + indent, y], width: content_width - indent, overflow: :shrink_to_fit
        y -= pt + 2
      end
      y - 4
    end

    def render_blockquote(pdf, block, margin_x, content_width, y)
      pt = SCALE_TO_PT[DEFAULT_SCALE]
      indent = pt

      block[:content].each_line do |line|
        # Draw pipe
        pdf.fill_color DIM_COLOR
        pdf.fill_rectangle [margin_x, y], 2, pt
        pdf.fill_color FG_COLOR

        formatted = build_formatted_text(line.chomp, pt).map { |f| f.merge(color: DIM_COLOR) }
        pdf.formatted_text_box formatted, at: [margin_x + indent, y], width: content_width - indent, overflow: :shrink_to_fit
        y -= pt + 2
      end
      y - 4
    end

    def render_table(pdf, block, margin_x, content_width, y)
      pt = SCALE_TO_PT[DEFAULT_SCALE] * 0.8
      row_height = pt * 1.6
      all_rows = [block[:header]] + block[:rows]
      num_cols = block[:header]&.size || 0
      return y if num_cols == 0

      col_width = content_width / num_cols.to_f

      all_rows.each_with_index do |cells, ri|
        next unless cells

        cells.each_with_index do |cell, ci|
          x = margin_x + ci * col_width
          styles = ri == 0 ? [:bold] : []
          pdf.formatted_text_box [{text: cell, size: pt, color: FG_COLOR, styles: styles}],
            at: [x + 4, y], width: col_width - 8, height: row_height, overflow: :shrink_to_fit
        end
        y -= row_height

        # Separator after header
        if ri == 0
          pdf.stroke_color DIM_COLOR
          pdf.line_width 0.5
          pdf.stroke_horizontal_line margin_x, margin_x + content_width, at: y + row_height * 0.3
          pdf.stroke_color FG_COLOR
        end
      end
      y - 4
    end

    def render_image(pdf, block, margin_x, content_width, y)
      path = resolve_image_path(block[:path])
      return y - SCALE_TO_PT[DEFAULT_SCALE] unless File.exist?(path)

      begin
        max_h = PAGE_HEIGHT * 0.6
        if (rh = block[:attrs]['relative_height'])
          max_h = PAGE_HEIGHT * rh.to_i / 100.0
        end

        img_size = ImageUtil.image_size(path)
        return y - SCALE_TO_PT[DEFAULT_SCALE] unless img_size

        img_w, img_h = img_size
        scale = [content_width / img_w.to_f, max_h / img_h.to_f, 1.0].min
        display_w = img_w * scale
        display_h = img_h * scale
        img_x = margin_x + (content_width - display_w) / 2.0

        pdf.image path, fit: [content_width, max_h], at: [img_x, y]
        y - display_h - 6
      rescue Prawn::Errors::UnsupportedImageType
        y - SCALE_TO_PT[DEFAULT_SCALE]
      end
    end

    def resolve_image_path(path)
      return path if File.absolute_path?(path) == path
      File.expand_path(path, @base_dir)
    end

    def build_formatted_text(text, default_pt)
      segments = Parser.parse_inline(text)
      segments.map { |segment|
        type = segment[0]
        content = segment[1]

        case type
        when :tag
          tag_name = segment[2]
          if (scale = Parser::SIZE_SCALES[tag_name])
            {text: content, size: SCALE_TO_PT[scale], color: FG_COLOR}
          elsif (hex = COLOR_MAP[tag_name])
            {text: content, size: default_pt, color: hex}
          elsif tag_name.match?(/\A[0-9a-fA-F]{6}\z/)
            {text: content, size: default_pt, color: tag_name.upcase}
          else
            {text: content, size: default_pt, color: FG_COLOR}
          end
        when :bold
          {text: content, size: default_pt, color: FG_COLOR, styles: [:bold]}
        when :italic
          {text: content, size: default_pt, color: FG_COLOR, styles: [:italic]}
        when :strikethrough
          {text: content, size: default_pt, color: FG_COLOR, styles: [:strikethrough]}
        when :code
          {text: " #{content} ", size: default_pt * 0.85, color: 'a6e3a1'}
        when :note
          {text: content, size: default_pt * 0.7, color: DIM_COLOR}
        when :text
          {text: content, size: default_pt, color: FG_COLOR}
        else
          {text: content.to_s, size: default_pt, color: FG_COLOR}
        end
      }
    end

    def max_inline_scale(text)
      max = 0
      text.scan(/\{::tag\s+name="([^"]+)"\}/) do
        scale = Parser::SIZE_SCALES[$1]
        max = scale if scale && scale > max
      end
      max > 0 ? max : nil
    end

    def heading_margin(pt)
      pt * 0.5
    end

    def estimate_slide_height(slide, content_width, pdf)
      h = 0
      slide.blocks.each do |block|
        case block[:type]
        when :heading
          scale = block[:level] == 1 ? KittyText::HEADING_SCALES[1] : DEFAULT_SCALE
          h += SCALE_TO_PT[scale] + (block[:level] == 1 ? heading_margin(SCALE_TO_PT[scale]) : 4)
        when :paragraph
          scale = max_inline_scale(block[:content]) || DEFAULT_SCALE
          h += SCALE_TO_PT[scale] + 2
        when :code_block
          lines = block[:content].lines.size
          pt = SCALE_TO_PT[DEFAULT_SCALE] * 0.7
          h += lines * pt * 1.4 + 16 + 6
        when :unordered_list
          h += block[:items].size * (SCALE_TO_PT[DEFAULT_SCALE] + 6)
        when :ordered_list
          h += block[:items].size * (SCALE_TO_PT[DEFAULT_SCALE] + 6)
        when :definition_list
          pt = SCALE_TO_PT[DEFAULT_SCALE]
          h += pt + 2 + block[:definition].lines.size * (pt + 2) + 4
        when :blockquote
          pt = SCALE_TO_PT[DEFAULT_SCALE]
          h += block[:content].lines.size * (pt + 2) + 4
        when :table
          pt = SCALE_TO_PT[DEFAULT_SCALE] * 0.8
          rows = (block[:header] ? 1 : 0) + block[:rows].size
          h += rows * pt * 1.6 + 4
        when :image
          h += PAGE_HEIGHT * 0.4
        when :blank
          h += SCALE_TO_PT[DEFAULT_SCALE]
        when :align
          # no height
        else
          h += SCALE_TO_PT[DEFAULT_SCALE]
        end
      end
      h
    end

  end
end
