# encoding: utf-8
# Экспорт фасадов — загрузчик расширения SketchUp.
# Автор: Артем Титов (motivate_rt)
#
# Автоматический экспорт 2D-геометрии фасадов в PNG:
# 4 фасада × 4 визуальные карты (Текстура, Линии, Тени, Окна) = 16 изображений.
#
# Совместимость: SketchUp 2021, 2025 и новее (Ruby 2.7+).

require 'sketchup.rb'
require 'extensions.rb'

module FacadeExport
  unless file_loaded?(__FILE__)
    MAIN = File.join(__dir__, 'facade_export', 'main.rb')

    extension = SketchupExtension.new('Экспорт фасадов', MAIN)
    extension.version     = '1.2.0'
    extension.creator     = 'Артем Титов motivate_rt'
    extension.copyright   = '© 2026 Артем Титов (motivate_rt)'
    extension.description = 'Автоматический экспорт фасадов в PNG: 4 фасада × 4 карты ' \
                            '(Текстура, Линии, Тени, Окна). Кадр 4:3 с большой стороной ' \
                            '9999 px, единый масштаб, тени 45° слева сверху, три типа ' \
                            'стекла, свои карты.'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
