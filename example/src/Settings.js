import React from 'react';
import { View, Text, Switch, StyleSheet, FlatList } from 'react-native';
import SelectDropdown from 'react-native-select-dropdown';

export const SettingsItem = ({ label, value, onValueChange, options }) => {
  if (typeof value === 'boolean') {
    return (
      <View style={styles.settingContainer}>
        <Text style={styles.settingLabel}>{label}</Text>
        <Switch value={value} onValueChange={onValueChange} />
      </View>
    );
  }

  return (
    <View style={styles.settingContainer}>
      <Text style={styles.settingLabel}>{label}</Text>
      <SelectDropdown
        data={options.items}
        onSelect={(selectedItem) => onValueChange(selectedItem.value)}
        defaultValue={options.items.find(item => item.value === value)}
        renderButton={(selectedItem, isOpen) => (
          <View style={styles.dropdownButtonStyle}>
            <Text style={styles.dropdownButtonTxtStyle}>
              {(selectedItem && selectedItem.label) || `Select ${label}`}
            </Text>
          </View>
        )}
        renderItem={(item, index, isSelected) => (
          <View style={[
            styles.dropdownItemStyle,
            isSelected && styles.dropdownItemSelectedStyle,
            index !== options.items.length - 1 && styles.dropdownItemBorder
          ]}>
            <Text style={styles.dropdownItemTxtStyle}>{item.label}</Text>
          </View>
        )}
        dropdownStyle={styles.dropdownMenuStyle}
        showsVerticalScrollIndicator={false}
      />
    </View>
  );
};

export const Settings = ({ settings, onSettingChange }) => {
  const settingsArray = Object.entries(settings).map(([key, value]) => ({
    key,
    label: key.split(/(?=[A-Z])/).join(' '),
    value: value.value || value,
    onValueChange: (newValue) => onSettingChange(key, newValue),
    options: value.items ? { items: value.items } : null,
  }));

  return (
    <FlatList
      data={settingsArray}
      renderItem={({ item }) => <SettingsItem label={item.label} value={item.value} onValueChange={item.onValueChange} options={item.options} />}
      keyExtractor={(item) => item.key}
      style={styles.settingsList}
    />
  );
};

const styles = StyleSheet.create({
  settingContainer: {
    marginBottom: 16,
  },
  settingLabel: {
    fontSize: 16,
    color: '#333',
    marginBottom: 8,
  },
  settingsList: {
    flexGrow: 0,
  },
  dropdownButtonStyle: {
    width: '100%',
    height: 50,
    backgroundColor: '#E9ECEF',
    borderRadius: 12,
    justifyContent: 'center',
    paddingHorizontal: 12,
  },
  dropdownButtonTxtStyle: {
    fontSize: 16,
    color: '#151E26',
    textAlign: 'left',
  },
  dropdownMenuStyle: {
    backgroundColor: '#E9ECEF',
    borderRadius: 8,
  },
  dropdownItemStyle: {
    width: '100%',
    justifyContent: 'flex-start',
    alignItems: 'center',
    paddingVertical: 12,
    paddingHorizontal: 12,
  },
  dropdownItemSelectedStyle: {
    backgroundColor: '#D2D9DF',
  },
  dropdownItemBorder: {
    borderBottomWidth: 1,
    borderBottomColor: '#E0E0E0',
  },
  dropdownItemTxtStyle: {
    fontSize: 16,
    color: '#151E26',
  },
});

export default Settings;