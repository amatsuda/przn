# frozen_string_literal: true

module Przn
  # Drives the laptop-side view in extended-display mode. Reuses the existing
  # Renderer to draw the current slide (notes still rendered dim-inline so the
  # presenter sees them in context), then overlays a three-line strip at the
  # bottom of the terminal: speaker notes summary, next-slide preview, and a
  # footer with the slide counter + elapsed time.
  class PresenterRenderer < Renderer
    def initialize(terminal, presentation:, base_dir: '.', theme: nil)
      super(terminal, base_dir: base_dir, theme: theme, mode: :presenter)
      @presentation = presentation
      @started_at = Time.now
    end

    def render(slide, current:, total:)
      super(slide, current: current, total: total)
      @mutex.synchronize { draw_presenter_strip(current, total) }
    end

    private

    def draw_presenter_strip(current, total)
      w = @terminal.width
      h = @terminal.height
      slide = @presentation.slides[current]
      notes_text = slide.notes.join(' / ')
      next_title = current + 1 < total ? preview_title(@presentation.slides[current + 1]) : nil
      elapsed = format_elapsed(Time.now - @started_at)
      footer = "Slide #{current + 1} / #{total}   #{elapsed}"

      @terminal.move_to(h - 2, 1)
      @terminal.write "#{ANSI[:dim]}Notes: #{truncate_to_width(notes_text, [w - 8, 1].max)}#{ANSI[:reset]}"
      @terminal.move_to(h - 1, 1)
      @terminal.write "#{ANSI[:dim]}Next:  #{truncate_to_width(next_title || '—', [w - 8, 1].max)}#{ANSI[:reset]}"
      @terminal.move_to(h, 1)
      @terminal.write "#{ANSI[:dim]}#{truncate_to_width(footer, w)}#{ANSI[:reset]}"
      @terminal.flush
    end

    def preview_title(slide)
      return nil unless slide
      slide.blocks.each do |b|
        case b[:type]
        when :heading, :paragraph then return strip_markup(b[:content].to_s)
        end
      end
      nil
    end

    def format_elapsed(seconds)
      h = (seconds / 3600).to_i
      m = ((seconds % 3600) / 60).to_i
      s = (seconds % 60).to_i
      format('%02d:%02d:%02d', h, m, s)
    end
  end
end
