import { Module } from '@nestjs/common';
import { BorrowingsController } from './borrowings.controller.js';
import { BorrowingsService } from './borrowings.service.js';

@Module({
  controllers: [BorrowingsController],
  providers: [BorrowingsService],
})
export class BorrowingsModule {}