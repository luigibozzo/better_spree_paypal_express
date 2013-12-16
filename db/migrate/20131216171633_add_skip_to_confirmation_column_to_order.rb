class AddSkipToConfirmationColumnToOrder < ActiveRecord::Migration
  def change
    add_column :spree_orders, :skip_to_confirmation, :boolean
  end
end
