# frozen_string_literal: true

module JSONTranslate
  module Translates
    SUFFIX = '_translations'
    MYSQL_ADAPTERS = %w[MySQL Mysql2 Mysql2Spatial].freeze

    def translates(*attrs, allow_blank: false)
      include InstanceMethods

      class_attribute :translated_attribute_names, :permitted_translated_attributes

      self.translated_attribute_names = attrs
      self.permitted_translated_attributes = [
        *self.ancestors
          .select {|klass| klass.respond_to?(:permitted_translated_attributes) }
          .map(&:permitted_translated_attributes),
        *attrs.product(I18n.available_locales)
          .map { |attribute, locale| :"#{attribute}_#{locale}" }
      ].flatten.compact

      attrs.each do |attr_name|
        define_method attr_name do |**params|
          if attribute_names.include?(attr_name.to_s)
            self[attr_name]
          else
            read_json_translation(attr_name, **params)
          end
        end

        define_method "#{attr_name}=" do |value|
          write_json_translation(attr_name, value, allow_blank: allow_blank)
        end

        I18n.available_locales.each do |locale|
          normalized_locale = locale.to_s.downcase.gsub(/[^a-z]/, '')

          define_method :"#{attr_name}_#{normalized_locale}" do |**params|
            read_json_translation(attr_name, locale: locale, fallback: false, **params)
          end

          define_method "#{attr_name}_#{normalized_locale}=" do |value|
            write_json_translation(attr_name, value, locale: locale, allow_blank: allow_blank)
          end
        end

        scope "with_#{attr_name}_translation", ->(value, locale = I18n.locale) {
          translation_store = arel_table["#{attr_name}#{SUFFIX}"]
          translation_json = Arel::Nodes.build_quoted({ locale => value }.to_json)

          if MYSQL_ADAPTERS.include?(connection.adapter_name)
            where(Arel::Nodes::NamedFunction.new(
                    'JSON_CONTAINS',
                    [
                      translation_store,
                      translation_json,
                      Arel::Nodes.build_quoted('$')
                    ]
                  ))
          else
            where(Arel::Nodes::InfixOperation.new(
                    '@>',
                    translation_store,
                    Arel::Nodes::NamedFunction.new('CAST', [translation_json.as('jsonb')])
                  ))
          end
        }

        define_singleton_method "arel_#{attr_name}" do |locale: I18n.locale, aliaz: nil|
          infix = Arel::Nodes::InfixOperation.new(
            '->',
            arel_table["#{attr_name}#{SUFFIX}"],
            Arel::Nodes.build_quoted(locale)
          )

          aliaz ? infix.as(aliaz.to_s) : infix
        end

        scope "select_#{attr_name}", ->(aliaz: attr_name, **options) {
          select(public_send("arel_#{attr_name}", **options, aliaz: aliaz))
        }

        scope "order_#{attr_name}", ->(direction: :asc, **options) {
          arel = public_send("arel_#{attr_name}", **options, aliaz: nil)
          order(direction.to_s.downcase == 'desc' ? arel.desc : arel)
        }
      end
    end

    def translates?
      included_modules.include?(InstanceMethods)
    end
  end
end
