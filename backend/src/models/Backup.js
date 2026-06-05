'use strict';

const mongoose = require('mongoose');

const { Schema } = mongoose;

const BackupSchema = new Schema(
  {
    user: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    filename: { type: String, required: true },
    size: { type: Number, default: 0 },
    note: { type: String, default: null },
    appVersion: { type: String, default: null },
  },
  { timestamps: { createdAt: 'createdAt', updatedAt: false } }
);

module.exports = mongoose.model('Backup', BackupSchema);
